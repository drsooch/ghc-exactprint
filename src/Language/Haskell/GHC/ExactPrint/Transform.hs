{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Language.Haskell.GHC.ExactPrint.Transform
--
-- This module is currently under heavy development, and no promises are made
-- about API stability. Use with care.
--
-- We weclome any feedback / contributions on this, as it is the main point of
-- the library.
--
-----------------------------------------------------------------------------
module Language.Haskell.GHC.ExactPrint.Transform
        (
        -- * The Transform Monad
          Transform
        , runTransform
        , runTransformFrom

        -- * Transform monad operations
        , logTr
        , getAnnsT, putAnnsT, modifyAnnsT
        , uniqueSrcSpanT

        , wrapSigT,wrapDeclT
        , pushDeclAnnT
        , decl2BindT,decl2SigT

        , cloneT

        , getEntryDPT
        , transferEntryDPT
        , addSimpleAnnT

        -- ** Managing lists, Transform monad
        , HasDecls (..)
        , insertAtStart
        , insertAtEnd
        , insertAfter
        , insertBefore

        -- *** Low level operations used in 'HasDecls'
        , balanceComments
        , balanceTrailingComments
        , moveTrailingComments

        -- ** Managing lists, pure functions
        , captureOrder
        , captureOrderAnnKey

        -- * Operations
        , isUniqueSrcSpan


        -- * Managing decls
        , declFun

        -- * Pure functions
        , mergeAnns
        , mergeAnnList
        , setPrecedingLinesDecl
        , setPrecedingLines
        , getEntryDP
        , transferEntryDP

        ) where

import Language.Haskell.GHC.ExactPrint.Types
import Language.Haskell.GHC.ExactPrint.Utils

import Control.Monad.RWS


import qualified Bag           as GHC
import qualified FastString    as GHC
import qualified GHC           as GHC hiding (parseModule)

import qualified Data.Generics as SYB

import Data.Data
import Data.Maybe

import qualified Data.Map as Map
import Control.Monad.Writer

-- import Debug.Trace

------------------------------------------------------------------------------
-- Transformation of source elements

-- | Monad type for updating the AST and managing the annotations at the same
-- time. The W state is used to generate logging information if required.
newtype Transform a = Transform { getTransform :: RWS () [String] (Anns,Int) a }
                        deriving (Monad, Applicative, Functor, MonadState (Anns, Int), MonadReader (), MonadWriter [String])

-- | Run a transformation in the 'Transform' monad, returning the updated
-- annotations and any logging generated via 'logTr'
runTransform :: Anns -> Transform a -> (a,(Anns,Int),[String])
runTransform ans f = runTransformFrom 0 ans f

-- | Run a transformation in the 'Transform' monad, returning the updated
-- annotations and any logging generated via 'logTr', allocating any new
-- SrcSpans from the provided initial value.
runTransformFrom :: Int -> Anns -> Transform a -> (a,(Anns,Int),[String])
runTransformFrom seed ans f = runRWS (getTransform f) () (ans,seed)

-- |Log a string to the output of the Monad
logTr :: String -> Transform ()
logTr str = tell [str]

-- |Access the 'Anns' being modified in this transformation
getAnnsT :: Transform Anns
getAnnsT = gets fst

-- |Replace the 'Anns' after any changes
putAnnsT :: Anns -> Transform ()
putAnnsT ans = do
  (_,col) <- get
  put (ans,col)

-- |Change the stored 'Anns'
modifyAnnsT :: (Anns -> Anns) -> Transform ()
modifyAnnsT f = do
  ans <- getAnnsT
  putAnnsT (f ans)

-- ---------------------------------------------------------------------

-- |Once we have 'Anns', a 'GHC.SrcSpan' is used purely as part of an 'AnnKey'
-- to index into the 'Anns'. If we need to add new elements to the AST, they
-- need their own 'GHC.SrcSpan' for this.
uniqueSrcSpanT :: Transform GHC.SrcSpan
uniqueSrcSpanT = do
  (an,col) <- get
  put (an,col + 1 )
  let pos = GHC.mkSrcLoc (GHC.mkFastString "ghc-exactprint") (-1) col
  return $ GHC.mkSrcSpan pos pos

-- |Test whether a given 'GHC.SrcSpan' was generated by 'uniqueSrcSpanT'
isUniqueSrcSpan :: GHC.SrcSpan -> Bool
isUniqueSrcSpan ss = srcSpanStartLine ss == -1

-- ---------------------------------------------------------------------

-- TODO: HaRe uses a NameMap from Located RdrName to Name, for being able to
--       rename elements. Consider how to manage this in the clone.

-- |Make a copy of an AST element, replacing the existing SrcSpans with new
-- ones, and duplicating the matching annotations.
cloneT :: (Data a,Typeable a) => a -> Transform (a, [(GHC.SrcSpan, GHC.SrcSpan)])
cloneT ast = do
  runWriterT $ SYB.everywhereM (return `SYB.ext2M` replaceLocated) ast
  where
    replaceLocated :: forall loc a. (Typeable loc,Typeable a, Data a)
                    => (GHC.GenLocated loc a) -> WriterT [(GHC.SrcSpan, GHC.SrcSpan)] Transform (GHC.GenLocated loc a)
    replaceLocated (GHC.L l t) = do
      case cast l :: Maybe GHC.SrcSpan of
        Just ss -> do
          newSpan <- lift uniqueSrcSpanT
          lift $ modifyAnnsT (\anns -> case Map.lookup (mkAnnKey (GHC.L ss t)) anns of
                                  Nothing -> anns
                                  Just an -> Map.insert (mkAnnKey (GHC.L newSpan t)) an anns)
          tell [(ss, newSpan)]
          return $ fromJust . cast  $ GHC.L newSpan t
        Nothing -> return (GHC.L l t)

-- ---------------------------------------------------------------------

-- |If a list has been re-ordered or had items added, capture the new order in
-- the appropriate 'annSortKey' attached to the 'Annotation' for the first
-- parameter.
captureOrder :: (Data a) => GHC.Located a -> [GHC.Located b] -> Anns -> Anns
captureOrder parent ls ans = captureOrderAnnKey (mkAnnKey parent) ls ans

-- |If a list has been re-ordered or had items added, capture the new order in
-- the appropriate 'annSortKey' item of the supplied 'AnnKey'
captureOrderAnnKey :: AnnKey -> [GHC.Located b] -> Anns -> Anns
captureOrderAnnKey parentKey ls ans = ans'
  where
    newList = map GHC.getLoc ls
    reList = Map.adjust (\an -> an {annSortKey = Just newList }) parentKey
    ans' = reList ans

-- ---------------------------------------------------------------------

-- |Pure function to convert a 'GHC.LHsDecl' to a 'GHC.LHsBind'. This does
-- nothing to any annotations that may be attached to either of the elements.
-- It is used as a utility function in 'replaceDecls'
decl2Bind :: GHC.LHsDecl name -> [GHC.LHsBind name]
decl2Bind (GHC.L l (GHC.ValD s)) = [GHC.L l s]
decl2Bind _                      = []

-- |Pure function to convert a 'GHC.LSig' to a 'GHC.LHsBind'. This does
-- nothing to any annotations that may be attached to either of the elements.
-- It is used as a utility function in 'replaceDecls'
decl2Sig :: GHC.LHsDecl name -> [GHC.LSig name]
decl2Sig (GHC.L l (GHC.SigD s)) = [GHC.L l s]
decl2Sig _                      = []

-- ---------------------------------------------------------------------

-- |Convert a 'GHC.LSig' into a 'GHC.LHsDecl', duplicating the 'GHC.LSig'
-- annotation for the 'GHC.LHsDecl'. This needs to be set up so that the
-- original annotation is restored after a 'pushDeclAnnT' call.
wrapSigT :: GHC.LSig GHC.RdrName -> Transform (GHC.LHsDecl GHC.RdrName)
wrapSigT d@(GHC.L _ s) = do
  newSpan <- uniqueSrcSpanT
  let
    f ans = case Map.lookup (mkAnnKey d) ans of
      Nothing -> ans
      Just ann ->
                  Map.insert (mkAnnKey (GHC.L newSpan s)) ann
                $ Map.insert (mkAnnKey (GHC.L newSpan (GHC.SigD s))) ann ans
  modifyAnnsT f
  return (GHC.L newSpan (GHC.SigD s))

-- ---------------------------------------------------------------------

-- |Convert a 'GHC.LHsBind' into a 'GHC.LHsDecl', duplicating the 'GHC.LHsBind'
-- annotation for the 'GHC.LHsDecl'. This needs to be set up so that the
-- original annotation is restored after a 'pushDeclAnnT' call.
wrapDeclT :: GHC.LHsBind GHC.RdrName -> Transform (GHC.LHsDecl GHC.RdrName)
wrapDeclT d@(GHC.L _ s) = do
  newSpan <- uniqueSrcSpanT
  let
    f ans = case Map.lookup (mkAnnKey d) ans of
      Nothing -> ans
      Just ann ->
                  Map.insert (mkAnnKey (GHC.L newSpan           s )) ann
                $ Map.insert (mkAnnKey (GHC.L newSpan (GHC.ValD s))) ann ans
  modifyAnnsT f
  return (GHC.L newSpan (GHC.ValD s))

-- ---------------------------------------------------------------------

-- |Copy the top level annotation to a new SrcSpan and the unwrapped decl. This
-- is required so that 'decl2Sig' and 'decl2Bind' will produce values that have
-- the required annotations.
pushDeclAnnT :: GHC.LHsDecl GHC.RdrName -> Transform (GHC.LHsDecl GHC.RdrName)
pushDeclAnnT ld@(GHC.L l decl) = do
  newSpan <- uniqueSrcSpanT
  let
    blend ann Nothing = ann
    blend ann (Just annd)
      = annd { annEntryDelta        = annEntryDelta ann
             , annPriorComments     = annPriorComments     ann  ++ annPriorComments     annd
             , annFollowingComments = annFollowingComments annd ++ annFollowingComments ann
             }
    duplicateAnn d ans =
      case Map.lookup (mkAnnKey ld) ans of
        Nothing -> error $ "pushDeclAnnT:no key found for:" ++ show (mkAnnKey ld)
        -- Nothing -> Anns ans
        Just ann -> Map.insert (mkAnnKey (GHC.L newSpan d))
                                      (blend ann (Map.lookup (mkAnnKey (GHC.L l d)) ans))
                                      ans
  case decl of
    GHC.TyClD d       -> modifyAnnsT (duplicateAnn d)
    GHC.InstD d       -> modifyAnnsT (duplicateAnn d)
    GHC.DerivD d      -> modifyAnnsT (duplicateAnn d)
    GHC.ValD d        -> modifyAnnsT (duplicateAnn d)
    GHC.SigD d        -> modifyAnnsT (duplicateAnn d)
    GHC.DefD d        -> modifyAnnsT (duplicateAnn d)
    GHC.ForD d        -> modifyAnnsT (duplicateAnn d)
    GHC.WarningD d    -> modifyAnnsT (duplicateAnn d)
    GHC.AnnD d        -> modifyAnnsT (duplicateAnn d)
    GHC.RuleD d       -> modifyAnnsT (duplicateAnn d)
    GHC.VectD d       -> modifyAnnsT (duplicateAnn d)
    GHC.SpliceD d     -> modifyAnnsT (duplicateAnn d)
    GHC.DocD d        -> modifyAnnsT (duplicateAnn d)
    GHC.RoleAnnotD d  -> modifyAnnsT (duplicateAnn d)
#if __GLASGOW_HASKELL__ < 711
    GHC.QuasiQuoteD d -> modifyAnnsT (duplicateAnn d)
#endif
  return (GHC.L newSpan decl)

-- ---------------------------------------------------------------------

-- |Unwrap a 'GHC.LHsDecl' to its underlying 'GHC.LHsBind', transferring the top
-- level annotation to a new unique 'GHC.SrcSpan' in the process.
decl2BindT :: GHC.LHsDecl GHC.RdrName -> Transform [GHC.LHsBind GHC.RdrName]
decl2BindT vd@(GHC.L _ (GHC.ValD d)) = do
  newSpan <- uniqueSrcSpanT
  logTr $ "decl2BindT:newSpan=" ++ showGhc newSpan
  let
    duplicateAnn ans =
      case Map.lookup (mkAnnKey vd) ans of
        Nothing -> ans
        Just ann -> Map.insert (mkAnnKey (GHC.L newSpan d)) ann ans
  modifyAnnsT duplicateAnn
  return [GHC.L newSpan d]
decl2BindT _ = return []

-- ---------------------------------------------------------------------

-- |Unwrap a 'GHC.LHsDecl' to its underlying 'GHC.LSig', transferring the top
-- level annotation to a new unique 'GHC.SrcSpan' in the process.
decl2SigT :: GHC.LHsDecl GHC.RdrName -> Transform [GHC.LSig GHC.RdrName]
decl2SigT vs@(GHC.L _ (GHC.SigD s)) = do
  newSpan <- uniqueSrcSpanT
  logTr $ "decl2SigT:newSpan=" ++ showGhc newSpan
  let
    duplicateAnn ans =
      case Map.lookup (mkAnnKey vs) ans of
        Nothing -> ans
        Just ann -> Map.insert (mkAnnKey (GHC.L newSpan s)) ann ans
  modifyAnnsT duplicateAnn
  return [GHC.L newSpan s]
decl2SigT _ = return []

-- ---------------------------------------------------------------------

-- |Create a simple 'Annotation' without comments, and attach it to the first
-- parameter.
addSimpleAnnT :: (Data a) => GHC.Located a -> DeltaPos -> [(KeywordId, DeltaPos)] -> Transform ()
addSimpleAnnT ast dp kds = do
  let ann = annNone { annEntryDelta = dp
                    , annsDP = kds
                    }
  modifyAnnsT (Map.insert (mkAnnKey ast) ann)

-- ---------------------------------------------------------------------

-- |'Transform' monad version of 'getEntryDP'
getEntryDPT :: (Data a) => GHC.Located a -> Transform DeltaPos
getEntryDPT ast = do
  anns <- getAnnsT
  return (getEntryDP anns ast)

-- ---------------------------------------------------------------------

-- |'Transform' monad version of 'transferEntryDP'
transferEntryDPT :: (Data a,Data b) => GHC.Located a -> GHC.Located b -> Transform ()
transferEntryDPT a b =
  modifyAnnsT (\anns -> transferEntryDP anns a b)

-- ---------------------------------------------------------------------

-- | Left bias pair union
mergeAnns :: Anns -> Anns -> Anns
mergeAnns
  = Map.union

-- |Combine a list of annotations
mergeAnnList :: [Anns] -> Anns
mergeAnnList [] = error "mergeAnnList must have at lease one entry"
mergeAnnList (x:xs) = foldr mergeAnns x xs

-- ---------------------------------------------------------------------

-- |Unwrap a HsDecl and call setPrecedingLines on it
setPrecedingLinesDecl :: GHC.LHsDecl GHC.RdrName -> Int -> Int -> Anns -> Anns
setPrecedingLinesDecl ld n c ans =
  declFun (\a -> setPrecedingLines a n c ans') ld
  where
    ans' = Map.insert (mkAnnKey ld) annNone ans

declFun :: (forall a . Data a => GHC.Located a -> b) -> GHC.LHsDecl GHC.RdrName -> b
declFun f (GHC.L l de) =
  case de of
      GHC.TyClD d       -> f (GHC.L l d)
      GHC.InstD d       -> f (GHC.L l d)
      GHC.DerivD d      -> f (GHC.L l d)
      GHC.ValD d        -> f (GHC.L l d)
      GHC.SigD d        -> f (GHC.L l d)
      GHC.DefD d        -> f (GHC.L l d)
      GHC.ForD d        -> f (GHC.L l d)
      GHC.WarningD d    -> f (GHC.L l d)
      GHC.AnnD d        -> f (GHC.L l d)
      GHC.RuleD d       -> f (GHC.L l d)
      GHC.VectD d       -> f (GHC.L l d)
      GHC.SpliceD d     -> f (GHC.L l d)
      GHC.DocD d        -> f (GHC.L l d)
      GHC.RoleAnnotD d  -> f (GHC.L l d)
#if __GLASGOW_HASKELL__ < 711
      GHC.QuasiQuoteD d -> f (GHC.L l d)
#endif

-- ---------------------------------------------------------------------

-- | Adjust the entry annotations to provide an `n` line preceding gap
setPrecedingLines :: (SYB.Data a) => GHC.Located a -> Int -> Int -> Anns -> Anns
setPrecedingLines ast n c anne =
  Map.alter go (mkAnnKey ast) anne
  where
    go Nothing  = Just (annNone { annEntryDelta = DP (n, c) })
    go (Just a) = Just (a       { annEntryDelta = DP (n, c) })

-- ---------------------------------------------------------------------

-- |Return the true entry 'DeltaPos' from the annotation for a given AST
-- element. This is the 'DeltaPos' ignoring any comments.
getEntryDP :: (Data a) => Anns -> GHC.Located a -> DeltaPos
getEntryDP anns ast =
  case Map.lookup (mkAnnKey ast) anns of
    Nothing  -> DP (0,0)
    Just ann -> annTrueEntryDelta ann
-- ---------------------------------------------------------------------

-- |Take the annEntryDelta associated with the first item and associate it with the second.
-- Also transfer the AnnSpanEntry value, and any comments occuring before it.
transferEntryDP :: (SYB.Data a, SYB.Data b) => Anns -> GHC.Located a -> GHC.Located b -> Anns
transferEntryDP ans a b = (const anns') ans
  where
    anns = ans
    maybeAnns = do -- Maybe monad
      anA <- Map.lookup (mkAnnKey a) anns
      anB <- Map.lookup (mkAnnKey b) anns
      let anB'  = Ann { annEntryDelta        = annEntryDelta     anA
                      , annPriorComments     = annPriorComments     anA ++ annPriorComments     anB
                      , annFollowingComments = annFollowingComments anA ++ annFollowingComments anB
                      , annsDP               = annsDP          anB
                      , annSortKey           = annSortKey      anB
                      , annCapturedSpan      = annCapturedSpan anB
                      }
      return (Map.insert (mkAnnKey b) anB' anns)
    anns' = fromMaybe
              (error $ "transferEntryDP: lookup failed (a,b)=" ++ show (mkAnnKey a,mkAnnKey b))
              maybeAnns

-- ---------------------------------------------------------------------

-- |Prior to moving an AST element, make sure any trailing comments belonging to
-- it are attached to it, and not the following element. Of necessity this is a
-- heuristic process, to be tuned later. Possibly a variant should be provided
-- with a passed-in decision function.
balanceComments :: (Data a,Data b) => GHC.Located a -> GHC.Located b -> Transform ()
balanceComments first second = do
  let
    k1 = mkAnnKey first
    k2 = mkAnnKey second
    moveComments p ans = ans'
      where
        an1 = gfromJust "balanceComments k1" $ Map.lookup k1 ans
        an2 = gfromJust "balanceComments k2" $ Map.lookup k2 ans
        -- cs1b = annPriorComments     an1
        cs1f = annFollowingComments an1
        cs2b = annPriorComments an2
        (move,stay) = break p cs2b
        an1' = an1 { annFollowingComments = cs1f ++ move}
        an2' = an2 { annPriorComments = stay}
        ans' = Map.insert k1 an1' $ Map.insert k2 an2' ans

    simpleBreak (_,DP (r,_c)) = r > 0

  modifyAnnsT (moveComments simpleBreak)

-- ---------------------------------------------------------------------

-- |After moving an AST element, make sure any comments that may belong
-- with the following element in fact do. Of necessity this is a heuristic
-- process, to be tuned later. Possibly a variant should be provided with a
-- passed-in decision function.
balanceTrailingComments :: (Data a,Data b) => GHC.Located a -> GHC.Located b -> Transform [(Comment, DeltaPos)]
balanceTrailingComments first second = do
  let
    k1 = mkAnnKey first
    k2 = mkAnnKey second
    moveComments p ans = (ans',move)
      where
        an1 = gfromJust "balanceTrailingComments k1" $ Map.lookup k1 ans
        an2 = gfromJust "balanceTrailingComments k2" $ Map.lookup k2 ans
        cs1f = annFollowingComments an1
        (move,stay) = break p cs1f
        an1' = an1 { annFollowingComments = stay }
        an2' = an2 -- { annPriorComments = move ++ cs2b }
        -- an1' = an1 { annFollowingComments = [] }
        -- an2' = an2 { annPriorComments = cs1f ++ cs2b }
        ans' = Map.insert k1 an1' $ Map.insert k2 an2' ans
        -- ans' = error $ "balanceTrailingComments:(k1,k2)=" ++ showGhc (k1,k2)
        -- ans' = error $ "balanceTrailingComments:(cs1b,cs1f,cs2b,annFollowingComments an2)=" ++ showGhc (cs1b,cs1f,cs2b,annFollowingComments an2)

    simpleBreak (_,DP (r,_c)) = r > 0

  -- modifyAnnsT (modifyKeywordDeltas (moveComments simpleBreak))
  ans <- getAnnsT
  let (ans',mov) = moveComments simpleBreak ans
  putAnnsT ans'
  return mov

-- ---------------------------------------------------------------------

-- |Move any 'annFollowingComments' values from the 'Annotation' associated to
-- the first parameter to that of the second.
moveTrailingComments :: (Data a,Data b)
                     => GHC.Located a -> GHC.Located b -> Transform ()
moveTrailingComments first second = do
  let
    k1 = mkAnnKey first
    k2 = mkAnnKey second
    moveComments ans = ans'
      where
        an1 = gfromJust "moveTrailingComments k1" $ Map.lookup k1 ans
        an2 = gfromJust "moveTrailingComments k2" $ Map.lookup k2 ans
        cs1f = annFollowingComments an1
        cs2f = annFollowingComments an2
        an1' = an1 { annFollowingComments = [] }
        an2' = an2 { annFollowingComments = cs1f ++ cs2f }
        ans' = Map.insert k1 an1' $ Map.insert k2 an2' ans

  modifyAnnsT moveComments

-- ---------------------------------------------------------------------

insertAt :: (Data ast, HasDecls (GHC.Located ast))
              => (GHC.SrcSpan -> [GHC.SrcSpan] -> [GHC.SrcSpan])
              -> GHC.Located ast
              -> GHC.LHsDecl GHC.RdrName
              -> Transform (GHC.Located ast)
insertAt f m decl = do
  let newKey = GHC.getLoc decl
      modKey = mkAnnKey m
      newValue a@Ann{..} = a { annSortKey = f newKey <$> annSortKey }
  oldDecls <- hsDecls m
  modifyAnnsT (Map.adjust newValue modKey)

  replaceDecls m (decl : oldDecls )

insertAtStart, insertAtEnd :: (Data ast, HasDecls (GHC.Located ast))
              => GHC.Located ast
              -> GHC.LHsDecl GHC.RdrName
              -> Transform (GHC.Located ast)

insertAtStart = insertAt (:)
insertAtEnd   = insertAt (\x xs -> xs ++ [x])

insertAfter, insertBefore :: (Data ast, HasDecls (GHC.Located ast))
                          => GHC.Located old
                          -> GHC.Located ast
                          -> GHC.LHsDecl GHC.RdrName
                          -> Transform (GHC.Located ast)
-- insertAfter (mkAnnKey -> k) = insertAt findAfter
insertAfter (GHC.getLoc -> k) = insertAt findAfter
  where
    findAfter x xs =
      let (fs, b:bs) = span (/= k) xs
      in fs ++ (b : x : bs)
insertBefore (GHC.getLoc -> k) = insertAt findBefore
  where
    findBefore x xs =
      let (fs, bs) = span (/= k) xs
      in fs ++ (x : bs)

-- =====================================================================
-- start of HasDecls instances
-- =====================================================================

class (Data t) => HasDecls t where

    -- | Return the 'GHC.HsDecl's that are directly enclosed in the
    -- given syntax phrase. They are always returned in the wrapped 'GHC.HsDecl'
    -- form, even if orginating in local decls.
    hsDecls :: t -> Transform [GHC.LHsDecl GHC.RdrName]

    -- | Replace the directly enclosed decl list by the given
    --  decl list. Runs in the 'Transform' monad to be able to update list order
    --  annotations, and rebalance comments and other layout changes as needed.
    --
    -- For example, a call on replaceDecls for a wrapped 'GHC.FunBind' having no
    -- where clause will convert
    --
    -- @
    -- -- |This is a function
    -- foo = x -- comment1
    -- @
    -- in to
    --
    -- @
    -- -- |This is a function
    -- foo = x -- comment1
    --   where
    --     nn = 2
    -- @
    replaceDecls :: t -> [GHC.LHsDecl GHC.RdrName] -> Transform t

-- ---------------------------------------------------------------------

instance HasDecls GHC.ParsedSource where
  hsDecls (GHC.L _ (GHC.HsModule _mn _exps _imps decls _ _)) = return decls
  replaceDecls m@(GHC.L l (GHC.HsModule mn exps imps _decls deps haddocks)) decls
    = do
        modifyAnnsT (captureOrder m decls)
        return (GHC.L l (GHC.HsModule mn exps imps decls deps haddocks))

-- ---------------------------------------------------------------------

instance HasDecls (GHC.MatchGroup GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  hsDecls (GHC.MG matches _ _ _) = hsDecls matches

  replaceDecls (GHC.MG matches a r o) newDecls
    = do
        matches' <- replaceDecls matches newDecls
        return (GHC.MG matches' a r o)

-- ---------------------------------------------------------------------

instance HasDecls [GHC.LMatch GHC.RdrName (GHC.LHsExpr GHC.RdrName)] where
  hsDecls ms = do
    ds <- mapM hsDecls ms
    return (concat ds)

  replaceDecls [] _        = error "empty match list in replaceDecls [GHC.LMatch GHC.Name]"
  replaceDecls ms newDecls
    = do
        -- ++AZ++: TODO: this one looks dodgy
        m' <- replaceDecls (ghead "replaceDecls" ms) newDecls
        return (m':tail ms)

-- ---------------------------------------------------------------------

instance HasDecls (GHC.LMatch GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  hsDecls (GHC.L _ (GHC.Match _ _ _ grhs)) = hsDecls grhs

  replaceDecls m@(GHC.L l (GHC.Match mf p t (GHC.GRHSs rhs binds))) []
    = do
        let
          noWhere (G GHC.AnnWhere,_) = False
          noWhere _                  = True

          removeWhere mkds =
            case Map.lookup (mkAnnKey m) mkds of
              Nothing -> error "wtf"
              Just ann -> Map.insert (mkAnnKey m) ann1 mkds
                where
                  ann1 = ann { annsDP = filter noWhere (annsDP ann)
                                 }
        modifyAnnsT removeWhere

        binds' <- replaceDecls binds []
        return (GHC.L l (GHC.Match mf p t (GHC.GRHSs rhs binds')))

  replaceDecls m@(GHC.L l (GHC.Match mf p t (GHC.GRHSs rhs binds))) newBinds
    = do
        -- Need to throw in a fresh where clause if the binds were empty,
        -- in the annotations.
        newBinds2 <- case binds of
          GHC.EmptyLocalBinds -> do
            let
              addWhere mkds =
                case Map.lookup (mkAnnKey m) mkds of
                  Nothing -> error "wtf"
                  Just ann -> Map.insert (mkAnnKey m) ann1 mkds
                    where
                      ann1 = ann { annsDP = annsDP ann ++ [(G GHC.AnnWhere,DP (1,2))]
                                 }
            modifyAnnsT addWhere
            newBinds' <- mapM pushDeclAnnT newBinds
            modifyAnnsT (captureOrderAnnKey (mkAnnKey m) newBinds')
            modifyAnnsT (setPrecedingLinesDecl (ghead "LMatch.replaceDecls" newBinds') 1 4)
            return newBinds'

          _ -> do
            -- ++AZ++ TODO: move the duplicate code out of the case statement
            newBinds' <- mapM pushDeclAnnT newBinds
            modifyAnnsT (captureOrderAnnKey (mkAnnKey m) newBinds')
            return newBinds'

        binds' <- replaceDecls binds newBinds2
        return (GHC.L l (GHC.Match mf p t (GHC.GRHSs rhs binds')))

-- ---------------------------------------------------------------------

instance HasDecls (GHC.GRHSs GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  hsDecls (GHC.GRHSs _ lb) = hsDecls lb

  replaceDecls (GHC.GRHSs rhss b) new
    = do
        b' <- replaceDecls b new
        return (GHC.GRHSs rhss b')

-- ---------------------------------------------------------------------

instance HasDecls (GHC.HsLocalBinds GHC.RdrName) where
  hsDecls lb = case lb of
    GHC.HsValBinds (GHC.ValBindsIn bs sigs) -> do
      bds <- mapM wrapDeclT (GHC.bagToList bs)
      sds <- mapM wrapSigT sigs
      -- ++AZ++ TODO: return in annotated order
      return (bds ++ sds)
    GHC.HsValBinds (GHC.ValBindsOut _ _) -> error $ "hsDecls.ValbindsOut not valid"
    GHC.HsIPBinds _     -> return []
    GHC.EmptyLocalBinds -> return []

  replaceDecls (GHC.HsValBinds _b) new
    = do
        let decs = GHC.listToBag $ concatMap decl2Bind new
        let sigs = concatMap decl2Sig new
        return (GHC.HsValBinds (GHC.ValBindsIn decs sigs))

  replaceDecls (GHC.HsIPBinds _b) _new    = error "undefined replaceDecls HsIPBinds"

  replaceDecls (GHC.EmptyLocalBinds) new
    = do
        let newBinds = map decl2Bind new
            newSigs  = map decl2Sig  new
        ans <- getAnnsT
        logTr $ "replaceDecls:newBinds=" ++ showAnnData ans 0 newBinds
        let decs = GHC.listToBag $ concat newBinds
        let sigs = concat newSigs
        return (GHC.HsValBinds (GHC.ValBindsIn decs sigs))

-- ---------------------------------------------------------------------

instance HasDecls (GHC.LHsExpr GHC.RdrName) where
  hsDecls (GHC.L _ (GHC.HsLet decls _ex)) = hsDecls decls
  hsDecls _                               = return []

  replaceDecls (GHC.L l (GHC.HsLet decls ex)) newDecls
    = do
        decls' <- replaceDecls decls newDecls
        return (GHC.L l (GHC.HsLet decls' ex))
  replaceDecls old _new = error $ "replaceDecls (GHC.LHsExpr GHC.RdrName) undefined for:" ++ showGhc old

-- ---------------------------------------------------------------------

instance HasDecls (GHC.LHsBinds GHC.RdrName) where
  hsDecls binds = hsDecls $ GHC.bagToList binds
  replaceDecls old _new = error $ "replaceDecls (GHC.LHsBinds name) undefined for:" ++ (showGhc old)

-- ---------------------------------------------------------------------

instance HasDecls [GHC.LHsBind GHC.RdrName] where
  hsDecls bs = mapM wrapDeclT bs

  replaceDecls _bs newDecls
    = do
        return $ concatMap decl2Bind newDecls

-- ---------------------------------------------------------------------

instance HasDecls (GHC.LHsBind GHC.RdrName) where
  hsDecls (GHC.L _ (GHC.FunBind _ _ matches _ _ _)) = hsDecls matches
  hsDecls (GHC.L _ (GHC.PatBind _ rhs _ _ _))       = hsDecls rhs
  hsDecls (GHC.L _ (GHC.VarBind _ rhs _))           = hsDecls rhs
  hsDecls (GHC.L _ (GHC.AbsBinds _ _ _ _ binds))    = hsDecls binds
  hsDecls (GHC.L _ (GHC.PatSynBind _))      = error "hsDecls: PatSynBind to implement"


  replaceDecls (GHC.L l fn@(GHC.FunBind a b (GHC.MG matches f g h) c d e)) newDecls
    = do
        matches' <- replaceDecls matches newDecls
        case matches' of
          [] -> return () -- Should be impossible
          ms -> do
            case (GHC.grhssLocalBinds $ GHC.m_grhss $ GHC.unLoc $ last matches) of
              GHC.EmptyLocalBinds -> do
                -- only move the comment if the original where clause was empty.
                toMove <- balanceTrailingComments (GHC.L l (GHC.ValD fn)) (last matches')
                insertCommentBefore (mkAnnKey $ last ms) toMove (matchApiAnn GHC.AnnWhere)
              lbs -> do
                decs <- hsDecls lbs
                balanceComments (last decs) (GHC.L l (GHC.ValD fn))
        return (GHC.L l (GHC.FunBind a b (GHC.MG matches' f g h) c d e))

  replaceDecls (GHC.L l (GHC.PatBind a rhs b c d)) newDecls
    = do
        rhs' <- replaceDecls rhs newDecls
        return (GHC.L l (GHC.PatBind a rhs' b c d))
  replaceDecls (GHC.L l (GHC.VarBind a rhs b)) newDecls
    = do
        rhs' <- replaceDecls rhs newDecls
        return (GHC.L l (GHC.VarBind a rhs' b))
  replaceDecls (GHC.L l (GHC.AbsBinds a b c d binds)) newDecls
    = do
        binds' <- replaceDecls binds newDecls
        return (GHC.L l (GHC.AbsBinds a b c d binds'))
  replaceDecls (GHC.L _ (GHC.PatSynBind _)) _ = error "replaceDecls: PatSynBind to implement"

-- ---------------------------------------------------------------------

instance HasDecls (GHC.Stmt GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  hsDecls (GHC.LetStmt lb)          = hsDecls lb
  hsDecls (GHC.LastStmt e _)        = hsDecls e
  hsDecls (GHC.BindStmt _pat e _ _) = hsDecls e
  hsDecls (GHC.BodyStmt e _ _ _)    = hsDecls e
  hsDecls _                         = return []

  replaceDecls (GHC.LetStmt lb) newDecls
    = do
      lb' <- replaceDecls lb newDecls
      return (GHC.LetStmt lb')
  replaceDecls (GHC.LastStmt e se) newDecls
    = do
        e' <- replaceDecls e newDecls
        return (GHC.LastStmt e' se)
  replaceDecls (GHC.BindStmt pat e a b) newDecls
    = do
      e' <- replaceDecls e newDecls
      return (GHC.BindStmt pat e' a b)
  replaceDecls (GHC.BodyStmt e a b c) newDecls
    = do
      e' <- replaceDecls e newDecls
      return (GHC.BodyStmt e' a b c)
  replaceDecls x _newDecls = return x

-- ---------------------------------------------------------------------

instance HasDecls (GHC.LHsDecl GHC.RdrName) where
  hsDecls (GHC.L l (GHC.ValD d)) = hsDecls (GHC.L l d)
  -- hsDecls (GHC.L l (GHC.SigD d)) = hsDecls (GHC.L l d)
  hsDecls _                      = return []

  replaceDecls (GHC.L l (GHC.ValD d)) newDecls = do
    (GHC.L l1 d1) <- replaceDecls (GHC.L l d) newDecls
    return (GHC.L l1 (GHC.ValD d1))
  -- replaceDecls (GHC.L l (GHC.SigD d)) newDecls = do
  --   (GHC.L l1 d1) <- replaceDecls (GHC.L l d) newDecls
  --   return (GHC.L l1 (GHC.SigD d1))
  replaceDecls _d _  = error $ "LHsDecl.replaceDecls:not implemented"


-- =====================================================================
-- end of HasDecls instances
-- =====================================================================

matchApiAnn :: GHC.AnnKeywordId -> (KeywordId,DeltaPos) -> Bool
matchApiAnn mkw (kw,_)
  = case kw of
     (G akw) -> mkw == akw
     _       -> False


-- We comments extracted from annPriorComments or annFollowingComments, which
-- need to move to just before the item identified by the predicate, if it
-- fires, else at the end of the annotations.
insertCommentBefore :: AnnKey -> [(Comment, DeltaPos)]
                    -> ((KeywordId, DeltaPos) -> Bool) -> Transform ()
insertCommentBefore key toMove p = do
  let
    doInsert ans =
      case Map.lookup key ans of
        Nothing -> error $ "insertCommentBefore:no AnnKey for:" ++ showGhc key
        Just ann -> Map.insert key ann' ans
          where
            (before,after) = break p (annsDP ann)
            -- ann' = error $ "insertCommentBefore:" ++ showGhc (before,after)
            ann' = ann { annsDP = before ++ (map comment2dp toMove) ++ after}

  modifyAnnsT doInsert
