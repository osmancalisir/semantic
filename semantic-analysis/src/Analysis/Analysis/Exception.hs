{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Analysis.Analysis.Exception
( Exception(..)
, ExcSet(..)
, exceptionTracing
, exceptionTracingIndependent
, instrumentLines
, fromExceptions
, var
, exc
, str
, subst
, nullExcSet
  -- * Line maps
, LineMap(..)
, lineMapFromList
, nullLineMap
, printLineMap
  -- * Exception tracing analysis
, ExcC(..)
) where

import qualified Analysis.Carrier.Statement.State as A
import qualified Analysis.Carrier.Store.Monovariant as A
import           Analysis.Effect.Domain
import           Analysis.Effect.Env (Env)
import           Analysis.Effect.Store
import           Analysis.File
import           Analysis.FlowInsensitive (cacheTerm, convergeTerm)
import           Analysis.Module
import           Analysis.Name
import           Analysis.Reference
import           Control.Algebra
import           Control.Applicative (Alternative (..))
import           Control.Carrier.Reader
import           Control.Carrier.Writer.Church
import           Control.Effect.Labelled
import           Control.Effect.State
import           Control.Monad (unless)
import           Data.Foldable (for_)
import qualified Data.Foldable as Foldable
import           Data.Function (fix)
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Source.Source as Source
import           Source.Span

-- | Names of exceptions thrown in the guest language and recorded by this analysis.
--
-- Not to be confused with exceptions thrown in Haskell itself.
newtype Exception = Exception { exceptionName :: Name }
  deriving (Eq, Ord, Show)

-- | Sets whose elements are each a variable or an exception.
data ExcSet = ExcSet { freeVariables :: Set.Set Name, exceptions :: Set.Set Exception, strings :: Set.Set Text.Text }
  deriving (Eq, Ord, Show)

instance Semigroup ExcSet where
  ExcSet v1 e1 s1 <> ExcSet v2 e2 s2 = ExcSet (v1 <> v2) (e1 <> e2) (s1 <> s2)

instance Monoid ExcSet where
  mempty = ExcSet mempty mempty mempty

fromExceptions :: Foldable t => t Exception -> ExcSet
fromExceptions es = ExcSet mempty (Set.fromList (Foldable.toList es)) mempty

var :: Name -> ExcSet
var v = ExcSet (Set.singleton v) mempty mempty

exc :: Exception -> ExcSet
exc e = ExcSet mempty (Set.singleton e) mempty

str :: Text.Text -> ExcSet
str s = ExcSet mempty mempty (Set.singleton s)

subst  :: Name -> ExcSet -> ExcSet -> ExcSet
subst name (ExcSet fvs' es' ss') (ExcSet fvs es ss) = ExcSet (Set.delete name fvs <> fvs') (es <> es') (ss <> ss')

nullExcSet :: ExcSet -> Bool
nullExcSet e = null (freeVariables e) && null (exceptions e)


newtype LineMap = LineMap { getLineMap :: IntMap.IntMap ExcSet }
  deriving (Show)

instance Semigroup LineMap where
  LineMap a <> LineMap b = LineMap (IntMap.unionWith (<>) a b)

instance Monoid LineMap where
  mempty = LineMap IntMap.empty

lineMapFromList :: [(Int, ExcSet)] -> LineMap
lineMapFromList = LineMap . IntMap.fromList

nullLineMap :: LineMap -> Bool
nullLineMap = null . getLineMap

printLineMap :: Source.Source -> LineMap -> IO ()
printLineMap src (LineMap lines) = for_ (zip [0..] (Source.lines src)) $ \ (i, line) -> do
  Text.putStr (Text.dropWhileEnd (== '\n') (Source.toText line))
  case lines IntMap.!? i of
    Just set | not (nullExcSet set) -> do
      Text.putStr (Text.pack " — ")
      Text.putStr (union
        [ formatFreeVariables (freeVariables set)
        , formatExceptions    (exceptions    set)
        ])
    _                               -> pure ()
  Text.putStrLn mempty
  where
  union = Text.intercalate (Text.pack " ∪ ")
  formatFreeVariables fvs  = union (map formatName (Set.toList fvs))
  formatExceptions    excs = Text.pack "{" <> union (map (formatName . exceptionName) (Set.toList excs)) <> Text.pack "}"

exceptionTracing
  :: Ord term
  => ( forall sig m
     .  (Has (Env A.MAddr) sig m, HasLabelled Store (Store A.MAddr ExcSet) sig m, Has (Dom ExcSet) sig m, Has (Reader Reference) sig m, Has A.Statement sig m, Has (Writer LineMap) sig m)
     => (term -> m ExcSet)
     -> (term -> m ExcSet) )
  -> [File term]
  -> (A.MStore ExcSet, [File (LineMap, Module ExcSet)])
exceptionTracing eval = run . A.runFiles (runWriter (\ lm f -> pure ((lm,) <$> f)) . runFile (instrumentLines eval))

exceptionTracingIndependent
  :: Ord term
  => ( forall sig m
     .  (Has (Env A.MAddr) sig m, HasLabelled Store (Store A.MAddr ExcSet) sig m, Has (Dom ExcSet) sig m, Has (Reader Reference) sig m, Has A.Statement sig m, Has (Writer LineMap) sig m)
     => (term -> m ExcSet)
     -> (term -> m ExcSet) )
  -> File term
  -> (A.MStore ExcSet, File (LineMap, Module ExcSet))
exceptionTracingIndependent eval = run . A.runStoreState . runWriter (\ lm f -> pure ((lm,) <$> f)) . runFile (instrumentLines eval)

instrumentLines :: (Has (Reader Reference) sig m, Has (Writer LineMap) sig m) => ((term -> m ExcSet) -> term -> m ExcSet) -> ((term -> m ExcSet) -> term -> m ExcSet)
instrumentLines eval recur term = do
  Reference _ (Span (Pos startLine _) (Pos endLine _) ) <- ask
  let lineNumbers = [startLine..endLine]
  (written, set) <- listen (eval recur term)
  unless (nullExcSet set || not (nullLineMap written)) $
    tell (lineMapFromList (map (, set) lineNumbers))
  pure set

runFile
  :: ( Has (State (A.MStore ExcSet)) sig m
     , Has (Writer LineMap) sig m
     , Ord term )
  => ( forall sig m
     .  (Has (Env A.MAddr) sig m, HasLabelled Store (Store A.MAddr ExcSet) sig m, Has (Dom ExcSet) sig m, Has (Reader Reference) sig m, Has A.Statement sig m, Has (Writer LineMap) sig m)
     => (term -> m ExcSet)
     -> (term -> m ExcSet) )
  -> File term
  -> m (File (Module ExcSet))
runFile eval file = traverse run file where
  run
    = A.runStatement result
    . A.runEnv @ExcSet
    . runReader (fileRef file)
    . convergeTerm (A.runStore @ExcSet . runExcC . fix (cacheTerm . eval))
  result msgs sets = do
    exports <- gets @(A.MStore ExcSet) (fmap Foldable.fold . Map.mapKeys A.getMAddr . A.getMStore)
    let set = Foldable.fold sets
        imports = Set.fromList (map extractImport msgs)
    pure (Module (Foldable.foldl' (flip (uncurry subst)) set . Map.toList) imports exports (freeVariables set))
  extractImport (A.Import components) = name (Text.intercalate (Text.pack ".") (Foldable.toList components))

newtype ExcC m a = ExcC { runExcC :: m a }
  deriving (Alternative, Applicative, Functor, Monad)

instance (Algebra sig m, Alternative m) => Algebra (Dom ExcSet :+: sig) (ExcC m) where
  alg hdl sig ctx = ExcC $ case sig of
    L dom   -> case dom of
      DVar n    -> pure $ var n <$ ctx
      DAbs _ b  -> runExcC (hdl (b mempty <$ ctx))
      DApp f a  -> pure $ f <> Foldable.fold a <$ ctx
      DInt _    -> pure nil
      DUnit     -> pure nil
      DBool _   -> pure nil
      DIf c t e -> fmap (mappend c) <$> runExcC (hdl (t <$ ctx) <|> hdl (e <$ ctx))
      DString s -> pure (str (Text.dropAround (== '"') s) <$ ctx)
      t :>>> u  -> pure (t <> u <$ ctx)
      DDie e    -> pure $ e{ strings = mempty } <> fromExceptions [Exception (name n) | n <- Set.toList (strings e)] <$ ctx
      where
      nil = (mempty :: ExcSet) <$ ctx

    R other -> alg (runExcC . hdl) other ctx
