-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.ShallowDeepPlugin.CondPass
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- Conditional Transformation Pass
-- if b then t else e ==> ifThenElse[Unit]E (rep b) t e
-------------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module System.Hardware.Haskino.ShallowDeepPlugin.CondPass (condPass) where

import CoreMonad
import GhcPlugins
import Data.List
import Data.Functor
import Control.Monad.Reader

import System.Hardware.Haskino.ShallowDeepPlugin.Utils

data CondEnv
    = CondEnv
      { pluginModGuts :: ModGuts
      }

newtype CondM a = CondM { runCondM :: ReaderT CondEnv CoreM a }
    deriving (Functor, Applicative, Monad
             ,MonadIO, MonadReader CondEnv)

instance PassCoreM CondM where
  liftCoreM = CondM . ReaderT . const
  getModGuts = CondM $ ReaderT (return . pluginModGuts)

condPass :: ModGuts -> CoreM ModGuts
condPass guts = do
    bindsOnlyPass (\x -> (runReaderT (runCondM $ (mapM condBind) x) (CondEnv guts))) guts

condBind :: CoreBind -> CondM CoreBind
condBind bndr@(NonRec b e) = do
  e' <- condExpr e
  return (NonRec b e')
condBind (Rec bs) = do
  bs' <- condExpr' bs
  return $ Rec bs'

condBind' :: [(Id, CoreExpr)] -> CondM [(Id, CoreExpr)]
condBind' [] = return []
condBind' ((b, e) : bs) = do
  e' <- condExpr e
  bs' <- condBind' bs
  return $ (b, e') : bs'

condExpr :: CoreExpr -> CondM CoreExpr
condExpr e = do
  df <- liftCoreM getDynFlags
  monadTyCon <- thNameToTyCon monadTyConTH
  unitTyCon <- thNameToTyCon ''()
  let unitTyConTy = mkTyConTy unitTyCon
  case e of
    Var v -> return $ Var v
    Lit l -> return $ Lit l
    Type ty -> return $ Type ty
    Coercion co -> return $ Coercion co
    App e1 e2 -> do
      e1' <- condExpr e1
      e2' <- condExpr e2
      return $ App e1' e2'
    Lam tb e -> do
      e' <- condExpr e
      return $ Lam tb e'
    Let bind body -> do
      body' <- condExpr body
      bind' <- case bind of
                  (NonRec v e) -> do
                    e' <- condExpr e
                    return $ NonRec v e'
                  (Rec rbs) -> do
                    rbs' <- condExpr' rbs
                    return $ Rec rbs'
      return $ Let bind' body'
    Case e tb ty alts -> do
      let tyCon_m = splitTyConApp_maybe ty
      e' <- condExpr e
      alts' <- condExprAlts alts
      case tyCon_m of
        Just (retTyCon, [retTy']) | retTyCon == monadTyCon -> do
            if length alts' == 2
            then case alts' of
              [(ac1, _, _), _] -> do
                case ac1 of
                  DataAlt d -> do
                    Just falseName <- liftCoreM $ thNameToGhcName falseNameTH
                    if (getName d) == falseName
                    then if retTy' `eqType` unitTyConTy
                         then condTransformUnit ty e' alts'
                         else condTransform ty e' alts'
                    else return $ Case e' tb ty alts'
                  _ -> return $ Case e' tb ty alts'
            else return $ Case e' tb ty alts'
        _ -> do
            return $ Case e' tb ty alts'
    Tick t e -> do
      e' <- condExpr e
      return $ Tick t e'
    Cast e co -> do
      e' <- condExpr e
      return $ Cast e' co

condExpr' :: [(Id, CoreExpr)] -> CondM [(Id, CoreExpr)]
condExpr' [] = return []
condExpr' ((b, e) : bs) = do
  e' <- condExpr e
  bs' <- condExpr' bs
  return $ (b, e') : bs'

condExprAlts :: [GhcPlugins.Alt CoreBndr] -> CondM [GhcPlugins.Alt CoreBndr]
condExprAlts [] = return []
condExprAlts ((ac, b, a) : as) = do
  a' <- condExpr a
  bs' <- condExprAlts as
  return $ (ac, b, a') : bs'

{-
  The following performs this transform:

    forall (b :: Bool) (t :: ArduinoConditional a => Arduino a) (e :: ArduinoConditional a => Arduino a).
    if b then t else e
      =
    rep_ <$> ifThenElseE (rep_ b) t e

    The return types of the then and else blocks are not changed until a later pass

-}
condTransform :: Type -> CoreExpr -> [GhcPlugins.Alt CoreBndr] -> CondM CoreExpr
condTransform ty e alts = do
  case alts of
    [(_, _, e1),(_, _, e2)] -> do
      -- Get the Arduino Type Con
      let Just tyCon'  = tyConAppTyCon_maybe ty
      let ty' = mkTyConTy tyCon'
      -- Get the Arduino Type Arg
      let Just [ty''] = tyConAppArgs_maybe ty
      -- Get the conditional type
      let bTy = exprType e

      ifThenElseId <- thNameToId ifThenElseNameTH
      condTyCon <- thNameToTyCon monadCondTyConTH
      condDict <- buildDictionaryTyConT condTyCon ty''

      repId <- thNameToId repNameTH

      exprBTyCon <- thNameToTyCon exprClassTyConTH
      repDict <- buildDictionaryTyConT exprBTyCon bTy

      exprTyCon <- thNameToTyCon exprTyConTH
      -- Make the type of the Expr for the specified type
      let exprTyConApp = GhcPlugins.mkTyConApp exprTyCon [ty'']

      -- Build the First Arg to ifThenElseE
      let arg1 = mkCoreApps (Var repId) [Type bTy, repDict, e]

      -- Build the ifThenElse Expr
      let ifteExpr = mkCoreApps (Var ifThenElseId) [Type ty'', condDict, arg1, e2, e1]

      return ifteExpr

{-
  The following performs this transform:

    forall (b :: Bool) (t :: Arduino ()) (e :: Arduino ()).
    if b then t else e
      =
    ifThenElseUnitE (rep_ b) t e

-}
condTransformUnit :: Type -> CoreExpr -> [GhcPlugins.Alt CoreBndr] -> CondM CoreExpr
condTransformUnit ty e alts = do
  case alts of
    [(_, _, e1),(_, _, e2)] -> do
      -- Get the conditional type
      let bTy = exprType e

      ifThenElseId <- thNameToId ifThenElseUnitNameTH

      repId <- thNameToId repNameTH
      exprBTyCon <- thNameToTyCon exprClassTyConTH
      repDict <- buildDictionaryTyConT exprBTyCon bTy

      -- Build the First Arg to ifThenElseUnitE
      let arg1 = mkCoreApps (Var repId) [Type bTy, repDict, e]

      return $ mkCoreApps (Var ifThenElseId) [arg1, e2, e1]