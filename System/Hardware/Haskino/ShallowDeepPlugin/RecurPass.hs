-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.ShallowDeepPlugin.RecurPass
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- Recursion Transformation Pass
-- if b then t else e ==> ifThenElse[Unit]E (rep b) t e
-------------------------------------------------------------------------------
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module System.Hardware.Haskino.ShallowDeepPlugin.RecurPass (recurPass) where

import CoreMonad
import GhcPlugins
import Data.List
import Data.Functor
import Control.Monad.State

import System.Hardware.Haskino.ShallowDeepPlugin.Utils

data BindEnv
    = BindEnv
      { pluginModGuts :: ModGuts,
        funcId        :: [Id],
        conds         :: [CoreExpr],
        dicts         :: [CoreExpr]
      }

newtype BindM a = BindM { runBindM :: StateT BindEnv CoreM a }
    deriving (Functor, Applicative, Monad
             ,MonadIO, MonadState BindEnv)

instance PassCoreM BindM where
    liftCoreM m = BindM $ lift m
    getModGuts = gets pluginModGuts

recurPass :: ModGuts -> CoreM ModGuts
recurPass guts = do
    bindsOnlyPass (\x -> fst <$> (runStateT (runBindM $ (mapM recurBind) x) (BindEnv guts [] [] []))) guts

recurBind :: CoreBind -> BindM CoreBind
recurBind bndr@(NonRec b e) = return bndr
recurBind (Rec bs) = do
    bs' <- recurBind' bs
    return $ Rec bs'

recurBind' :: [(Id, CoreExpr)] -> BindM [(Id, CoreExpr)]
recurBind' [] = return []
recurBind' ((b, e) : bs) = do
    let defaultRet = do
        bs' <- recurBind' bs
        return $ (b, e) : bs'
    s <- get
    put s {funcId = [b], conds = []}
    let (argTys, retTy) = splitFunTys $ exprType e
    let tyCon_m = splitTyConApp_maybe retTy
    monadTyCon <- thNameToTyCon monadTyConTH
    case tyCon_m of
        Just (tyCon, [tyArg]) -> do
            if length argTys == 1 && tyCon == monadTyCon
            then do
                s <- get
                put s {funcId = [b]}
                liftCoreM $ putMsgS "One Arg Arudino Rec Bind"
                liftCoreM $ putMsg $ ppr b
                liftCoreM $ putMsg $ ppr argTys
                liftCoreM $ putMsg $ ppr retTy
                let (lbs, e') = collectBinders e
                (e'', hasAp)  <- checkForRecur True e'
                (e''', hasAp) <- checkForRecur False e'
                liftCoreM $ putMsgS "Step Pass = "
                liftCoreM $ putMsg $ ppr e''
                liftCoreM $ putMsgS "Done Pass = "
                liftCoreM $ putMsg $ ppr e'''
                conds <- gets conds
                whileCond <- genWhileCond conds
                liftCoreM $ putMsgS "Whild Cond = "
                liftCoreM $ putMsg $ ppr whileCond
                bs' <- recurBind' bs
                return $ (b, mkLams lbs e'') : bs'
            else defaultRet
        _ -> defaultRet


checkForRecur :: Bool -> CoreExpr -> BindM (CoreExpr, Bool)
checkForRecur step e = do
    funcId <- gets funcId
    df <- liftCoreM getDynFlags
    let (bs, e') = collectBinders e
    let (f, args) = collectArgs e'
    bindId <- thNameToId bindNameTH
    thenId <- thNameToId bindThenNameTH
    fmapId <- thNameToId fmapNameTH
    apId <- thNameToId apNameTH
    case f of
      Var fv -> do
          -- Check if we have reached the bottom of the bind chain or if
          -- there is another level.
          if fv == bindId || fv == thenId
          then do
              -- TBD - This is a hack, need to generate dictionary 
              -- not copy it from a bind.
              s <- get               
              put s {dicts = [args !! 1]}              
              -- Check if the next level has a recur
              (e'', recurFlag) <- checkForRecur step $ last args
              let e''' = mkCoreApps f ((init args) ++ [e''])
              return $ (mkLams bs e''', recurFlag)
          else
              -- We are at the bottom of the bind chain.....
              -- Check for recursive call.
              -- Either in the form of (Var funcId) arg ...
              if fv == head funcId
              then do
                  ret_e <- genReturn $ head args
                  return (mkLams bs ret_e, True)
              -- ... Or in the form of (Var funcId) $ arg
              else if fv == apId
                   then case args of
                       [_, _, _, Var fv', arg] | fv' == head funcId -> do
                           ret_e <- genReturn arg
                           return (mkLams bs ret_e, True)
                       _ -> return (e, False)
                   else return (e, False)
      Case e' tb ty alts -> do
          alts' <- checkAltsForRecur step e' alts
          return (Case e' tb ty alts', False)
      _ -> return (e, False)


checkAltsForRecur :: Bool -> CoreExpr -> [GhcPlugins.Alt CoreBndr] -> BindM [GhcPlugins.Alt CoreBndr]
checkAltsForRecur _ _ [] = return []
checkAltsForRecur step e ((ac, b, a) : as) = do
    recurErrName <- thNameToId recurErrNameTH
    (a', hasAp) <- checkForRecur step a
    a'' <- if hasAp
           then do
              -- For a Step branch, save the conditional
              e' <- case ac of
                      DataAlt d -> do
                        Just falseName <- liftCoreM $ thNameToGhcName falseNameTH
                        -- if d == falseName
                        if (getName d) == falseName
                        then do
                          -- If we are in the False branch of the case, we
                          -- need to negate the conditional
                          notName <- thNameToId notNameTH
                          return $ mkCoreApps (Var notName) [e]
                        else return e
              if step
              then do
                  -- Add conditional to list to generate while conditional
                  -- during the Step phase.
                  s <- get
                  put s {conds = e' : conds s}
                  return a'
              else return (Var recurErrName)
           else if step
                then return (Var recurErrName)
                else return a'
    bs' <- checkAltsForRecur step e as
    return $ (ac, b, a'') : bs'

genReturn :: CoreExpr -> BindM CoreExpr
genReturn e = do
    dicts <- gets dicts
    returnId <- thNameToId returnNameTH
    monadTyConId <- thNameToTyCon monadTyConTH
    let monadTyConTy = mkTyConTy monadTyConId
    -- dict <- buildDictionaryTyConT (tyConAppTyCon monadTyConTy) $ exprType e
    return $ mkCoreApps (Var returnId) [Type monadTyConTy, head dicts, Type (exprType e), e]

genWhileCond :: [CoreExpr] -> BindM CoreExpr
genWhileCond [c]        = return c
genWhileCond [c1,c2]    = do
    andId <- thNameToId andNameTH
    return $ mkCoreApps (Var andId) [c1, c2]
genWhileCond (c:cs) = do
    andId <- thNameToId andNameTH
    gcs <- genWhileCond cs
    return $ mkCoreApps (Var andId) [c, gcs]
 
