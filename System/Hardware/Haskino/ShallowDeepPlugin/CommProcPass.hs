-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.ShallowDeepPlugin.CommProcPass
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- Conditional Transformation Pass
-- if b then t else e ==> ifThenElse[Unit]E (rep b) t e
-------------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module System.Hardware.Haskino.ShallowDeepPlugin.CommProcPass (commProcPass) where

import CoreMonad
import GhcPlugins
import Type
import Data.List
import Data.Functor
import Control.Monad.Reader

import System.Hardware.Haskino.ShallowDeepPlugin.Utils

import qualified System.Hardware.Haskino

data XlatEntry = XlatEntry {  fromId   :: BindM Id
                            , toId     :: BindM Id
                           }

-- The following talbe defines the names of the Shallow DSL functions
-- to translate from and the Deep DSL functions to translate to.
xlatList :: [XlatEntry]
xlatList = [  XlatEntry (thNameToId 'System.Hardware.Haskino.loop)
                        (thNameToId 'System.Hardware.Haskino.loopE)
            , XlatEntry (thNameToId 'System.Hardware.Haskino.setPinMode)
                        (thNameToId 'System.Hardware.Haskino.setPinModeE)
            , XlatEntry (thNameToId 'System.Hardware.Haskino.digitalRead)
                        (thNameToId 'System.Hardware.Haskino.digitalReadE)
            , XlatEntry (thNameToId 'System.Hardware.Haskino.digitalWrite)
                        (thNameToId 'System.Hardware.Haskino.digitalWriteE)
            , XlatEntry (thNameToId 'System.Hardware.Haskino.delayMillis)
                        (thNameToId 'System.Hardware.Haskino.delayMillisE)
           ]

data BindEnv
    = BindEnv
      { pluginModGuts :: ModGuts
      }

newtype BindM a = BindM { runCondM :: ReaderT BindEnv CoreM a }
    deriving (Functor, Applicative, Monad
             ,MonadIO, MonadReader BindEnv)

instance PassCoreM BindM where
  liftCoreM = BindM . ReaderT . const
  getModGuts = BindM $ ReaderT (return . pluginModGuts)

commProcPass :: ModGuts -> CoreM ModGuts
commProcPass guts = do
    bindsOnlyPass (\x -> (runReaderT (runCondM $ (mapM commProcBind) x) (BindEnv guts))) guts

commProcBind :: CoreBind -> BindM CoreBind
commProcBind bndr@(NonRec b e) = do
  e' <- commProcExpr e
  return (NonRec b e')
commProcBind (Rec bs) = do
  bs' <- commProcExpr' bs
  return $ Rec bs'

funcInXlatList :: Id -> BindM (Maybe XlatEntry)
funcInXlatList id = do
  funcInXlatList' id xlatList
    where
      funcInXlatList' :: Id -> [XlatEntry] -> BindM (Maybe XlatEntry)
      funcInXlatList' id [] = return Nothing
      funcInXlatList' id (xl:xls) = do
          fId <- fromId xl
          if fId == id
          then return $ Just xl
          else funcInXlatList' id xls

commProcExpr :: CoreExpr -> BindM CoreExpr
commProcExpr e = do
  df <- liftCoreM getDynFlags
  case e of
    Var v -> do
      inList <- funcInXlatList v
      case inList of
          Just xe -> do
            v' <- toId xe
            return $ Var v'
          Nothing -> return $ Var v
    Lit l -> return $ Lit l
    Type ty -> return $ Type ty
    Coercion co -> return $ Coercion co
    App e1 e2 -> do
      let (f, args) = collectArgs e
      case f of
          Var v -> do
              inList <- funcInXlatList v
              case inList of
                  Just xe -> commProcXlat xe e
                  Nothing -> do
                      e1' <- commProcExpr e1
                      e2' <- commProcExpr e2
                      return $ App e1' e2'
          _ -> do
              e1' <- commProcExpr e1
              e2' <- commProcExpr e2
              return $ App e1' e2'
    Lam tb e -> do
      e' <- commProcExpr e
      return $ Lam tb e'
    Let bind body -> do
      body' <- commProcExpr body
      bind' <- case bind of
                  (NonRec v e) -> do
                    e' <- commProcExpr e
                    return $ NonRec v e'
                  (Rec rbs) -> do
                    rbs' <- commProcExpr' rbs
                    return $ Rec rbs'
      return $ Let bind' body'
    Case e tb ty alts -> do
      e' <- commProcExpr e
      alts' <- commProcExprAlts alts
      return $ Case e' tb ty alts'
    Tick t e -> do
      e' <- commProcExpr e
      return $ Tick t e'
    Cast e co -> do
      e' <- commProcExpr e
      return $ Cast e' co

commProcExpr' :: [(Id, CoreExpr)] -> BindM [(Id, CoreExpr)]
commProcExpr' [] = return []
commProcExpr' ((b, e) : bs) = do
  e' <- commProcExpr e
  bs' <- commProcExpr' bs
  return $ (b, e') : bs'

commProcExprAlts :: [GhcPlugins.Alt CoreBndr] -> BindM [GhcPlugins.Alt CoreBndr]
commProcExprAlts [] = return []
commProcExprAlts ((ac, b, a) : as) = do
  a' <- commProcExpr a
  bs' <- commProcExprAlts as
  return $ (ac, b, a') : bs'

commProcXlat :: XlatEntry -> CoreExpr -> BindM CoreExpr
commProcXlat xe e = do
  let (f, args) = collectArgs e
  (xlatRet, xlatArgs) <- genXlatBools (fromId xe) (toId xe)
  let zargs = zip xlatArgs args
  args' <- mapM commProcXlatArg zargs
  newId <- toId xe
  let f' = Var newId

  if xlatRet
  then do
    let (tyCon, [ty]) = splitTyConApp $ exprType e
    let tyConTy = mkTyConTy tyCon

    exprTyCon <- thNameToTyCon exprTyConTH
    let exprTy = mkTyConApp exprTyCon [ty]

    fmapId <- thNameToId fmapNameTH
    functTyCon <- thNameToTyCon functTyConTH
    functDict <- buildDictionaryTyConT functTyCon tyConTy

    -- Build the abs_ function
    absId <- thNameToId absNameTH

    let abs = App (Var absId) (Type ty)
    -- Build the <$> applied to the abs_ and the original app
    return $ mkCoreApps (Var fmapId) [Type tyConTy, Type exprTy, Type ty, functDict, abs, mkCoreApps f' args']
  else
    return $ mkCoreApps f' args'

genXlatBools :: BindM Id -> BindM Id -> BindM (Bool, [Bool])
genXlatBools from to = do
  f <- from
  t <- to
  let (fTys, fRetTy) = splitFunTys $ exprType $ Var f
  let (tTys, tRetTy) = splitFunTys $ exprType $ Var t
  let zTys = zip fTys tTys
  let changeArgs = map (\(x,y) -> not $ x `eqType` y) zTys
  return $ (not $ fRetTy `eqType` tRetTy, changeArgs)

commProcXlatArg :: (Bool, CoreExpr) -> BindM CoreExpr
commProcXlatArg (xlat, e) =
  if xlat
  then do
    let ty = exprType e
    repId <- thNameToId repNameTH
    exprBTyCon <- thNameToTyCon exprClassTyConTH
    repDict <- buildDictionaryTyConT exprBTyCon ty
    return $ mkCoreApps (Var repId) [Type ty, repDict, e]
  else return e
