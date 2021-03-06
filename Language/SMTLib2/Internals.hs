{-# LANGUAGE OverloadedStrings,GADTs,FlexibleInstances,MultiParamTypeClasses,RankNTypes,DeriveDataTypeable,TypeSynonymInstances,TypeFamilies,FlexibleContexts,CPP,ScopedTypeVariables,GeneralizedNewtypeDeriving #-}
module Language.SMTLib2.Internals where

import Language.SMTLib2.Internals.Operators
import Language.SMTLib2.Strategy

import Data.Typeable
import Data.Map as Map hiding (assocs,foldl)
import Data.Ratio
import Data.Proxy
#ifdef SMTLIB2_WITH_CONSTRAINTS
import Data.Constraint
#endif
#ifdef SMTLIB2_WITH_DATAKINDS
import Data.Tagged
import Data.List as List (genericReplicate)
#endif
import Data.Fix
import Prelude hiding (mapM,mapM_,foldl,all,maximum)
import Data.Foldable
import Data.Traversable
import Control.Exception
import Data.Functor.Identity
import Data.Char (isDigit)

-- Monad stuff
import Control.Applicative (Applicative(..))
import Control.Monad.Trans
import Control.Monad.Fix
import Control.Monad (ap,when)

data SMTRequest response where
  SMTSetLogic :: String -> SMTRequest ()
  SMTGetInfo :: SMTInfo i -> SMTRequest i
  SMTSetOption :: SMTOption -> SMTRequest ()
  SMTAssert :: SMTExpr Bool -> Maybe InterpolationGroup -> Maybe ClauseId -> SMTRequest ()
  SMTCheckSat :: Maybe Tactic -> CheckSatLimits -> SMTRequest CheckSatResult
  SMTDeclaredDataTypes :: SMTRequest DataTypeInfo
  SMTDeclareDataTypes :: TypeCollection -> SMTRequest ()
  SMTDeclareSort :: String -> Integer -> SMTRequest ()
  SMTPush :: SMTRequest ()
  SMTPop :: SMTRequest ()
  SMTDefineFun :: (Args arg,SMTType res) => Maybe String -> Proxy arg -> ArgAnnotation arg -> SMTExpr res -> SMTRequest Integer
  SMTDeclareFun :: FunInfo -> SMTRequest Integer
  SMTGetValue :: SMTValue t => SMTExpr t -> SMTRequest t
  SMTGetModel :: SMTRequest SMTModel
  SMTGetProof :: SMTRequest (SMTExpr Bool)
  SMTGetUnsatCore :: SMTRequest [ClauseId]
  SMTSimplify :: SMTType t => SMTExpr t -> SMTRequest (SMTExpr t)
  SMTGetInterpolant :: [InterpolationGroup] -> SMTRequest (SMTExpr Bool)
  SMTInterpolate :: [SMTExpr Bool] -> SMTRequest [SMTExpr Bool]
  SMTComment :: String -> SMTRequest ()
  SMTExit :: SMTRequest ()
  SMTApply :: Tactic -> SMTRequest [SMTExpr Bool]
  SMTNameExpr :: SMTType t => String -> SMTExpr t -> SMTRequest Integer
  SMTNewInterpolationGroup :: SMTRequest InterpolationGroup
  SMTNewClauseId :: SMTRequest ClauseId
  deriving Typeable

data SMTModel = SMTModel { modelFunctions :: Map Integer (Integer,[ProxyArg],SMTExpr Untyped)
                         } deriving (Show,Typeable)

-- | Describe limits on the ressources that an SMT-solver can use
data CheckSatLimits = CheckSatLimits { limitTime :: Maybe Integer -- ^ A limit on the amount of time the solver can spend on the problem (in milliseconds)
                                     , limitMemory :: Maybe Integer -- ^ A limit on the amount of memory the solver can use (in megabytes)
                                     } deriving (Show,Eq,Ord,Typeable)

-- | The result of a check-sat query
data CheckSatResult
  = Sat -- ^ The formula is satisfiable
  | Unsat -- ^ The formula is unsatisfiable
  | Unknown -- ^ The solver cannot determine the satisfiability of a formula
  deriving (Show,Eq,Ord,Typeable)

class Monad m => SMTBackend a m where
  smtHandle :: Typeable response => a -> SMTRequest response -> m (response,a)
  smtGetNames :: a -> m (Integer -> String)
  smtNextName :: a -> m (Maybe String -> String)

-- | Haskell types which can be represented in SMT
class (Ord t,Typeable t,
       Ord (SMTAnnotation t),Typeable (SMTAnnotation t),Show (SMTAnnotation t))
      => SMTType t where
  type SMTAnnotation t
  getSort :: t -> SMTAnnotation t -> Sort
  asDataType :: t -> SMTAnnotation t -> Maybe (String,TypeCollection)
  asDataType _ _ = Nothing
  asValueType :: t -> SMTAnnotation t -> (forall v. SMTValue v => v -> SMTAnnotation v -> r) -> Maybe r
  getProxyArgs :: t -> SMTAnnotation t -> [ProxyArg]
  getProxyArgs _ _ = []
  additionalConstraints :: t -> SMTAnnotation t -> Maybe (SMTExpr t -> [SMTExpr Bool])
  additionalConstraints _ _ = Nothing
  annotationFromSort :: t -> Sort -> SMTAnnotation t
  defaultExpr :: SMTAnnotation t -> SMTExpr t

data ArgumentSort' a = ArgumentSort Integer
                     | NormalSort (Sort' a)

type ArgumentSort = Fix ArgumentSort'

data Unmangling a = PrimitiveUnmangling (Value -> SMTAnnotation a -> Maybe a)
                  | ComplexUnmangling (forall m s. Monad m => (forall b. SMTValue b => s -> SMTExpr b -> SMTAnnotation b -> m (b,s)) -> s -> SMTExpr a -> SMTAnnotation a -> m (Maybe a,s))

data Mangling a = PrimitiveMangling (a -> SMTAnnotation a -> Value)
                | ComplexMangling (a -> SMTAnnotation a -> SMTExpr a)

-- | Haskell values which can be represented as SMT constants
class (SMTType t,Show t) => SMTValue t where
  unmangle :: Unmangling t
  mangle :: Mangling t

-- | A type class for all types which support arithmetic operations in SMT
class (SMTValue t,Num t) => SMTArith t

-- | Lifts the 'Ord' class into SMT
class (SMTType t) => SMTOrd t where
  (.<.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.>.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool
  (.<=.) :: SMTExpr t -> SMTExpr t -> SMTExpr Bool

infix 4 .<., .<=., .>=., .>.

-- | An array which maps indices of type /i/ to elements of type /v/.
data SMTArray (i :: *) (v :: *) = SMTArray deriving (Eq,Ord,Typeable)

data FunInfo = forall arg r. (Args arg,SMTType r) => FunInfo { funInfoProxy :: Proxy (arg,r)
                                                             , funInfoArgAnn :: ArgAnnotation arg
                                                             , funInfoResAnn :: SMTAnnotation r
                                                             , funInfoName :: Maybe String
                                                             }

data AnyBackend m = forall b. SMTBackend b m => AnyBackend b

-- | The SMT monad used for communating with the SMT solver
data SMT' m a = SMT { runSMT :: forall b. SMTBackend b m => b -> m (a,b) }

type SMT = SMT' IO

instance Functor m => Functor (SMT' m) where
  fmap f (SMT g) = SMT $ \b -> fmap (\(r,b) -> (f r,b)) (g b)

instance Monad m => Monad (SMT' m) where
  return x = SMT $ \b -> return (x,b)
  (SMT f) >>= g = SMT $ \b -> do
    (r,b1) <- f b
    case g r of
     SMT act -> act b1

instance MonadIO m => MonadIO (SMT' m) where
  liftIO act = SMT $ \b -> do
    res <- liftIO act
    return (res,b)

instance MonadFix m => MonadFix (SMT' m) where
  mfix f = SMT $ \b -> mfix (\(~(res,_)) -> case f res of
                              ~(SMT act) -> act b)

instance (Monad m,Functor m) => Applicative (SMT' m) where
  pure = return
  (<*>) = ap

smtBackend :: Monad m => (forall b. SMTBackend b m => b -> m (res,b)) -> SMT' m res
smtBackend f = SMT f

instance MonadTrans SMT' where
  lift act = SMT $ \b -> do
    res <- act
    return (res,b)

data Untyped = forall t. SMTType t => Untyped t deriving Typeable

data UntypedValue = forall t. SMTValue t => UntypedValue t deriving Typeable

instance Eq Untyped where
  (Untyped x) == (Untyped y) = case cast y of
    Just y' -> x==y'
    Nothing -> False

instance Ord Untyped where
  compare (Untyped x) (Untyped y) = case compare (typeOf x) (typeOf y) of
    EQ -> case cast y of
      Just y' -> compare x y'
    r -> r

instance Eq UntypedValue where
  (UntypedValue x) == (UntypedValue y) = case cast y of
    Just y' -> x==y'
    Nothing -> False

instance Ord UntypedValue where
  compare (UntypedValue x) (UntypedValue y) = case compare (typeOf x) (typeOf y) of
    EQ -> case cast y of
      Just y' -> compare x y'
    r -> r

instance Show UntypedValue where
  showsPrec p (UntypedValue x) = showsPrec p x

-- | An abstract SMT expression
data SMTExpr t where
  Var :: SMTType t => Integer -> SMTAnnotation t -> SMTExpr t
  QVar :: SMTType t => Integer -> Integer -> SMTAnnotation t -> SMTExpr t
  FunArg :: SMTType t => Integer -> SMTAnnotation t -> SMTExpr t
  Const :: SMTValue t => t -> SMTAnnotation t -> SMTExpr t
  AsArray :: (Args arg,SMTType res) => SMTFunction arg res -> ArgAnnotation arg
             -> SMTExpr (SMTArray arg res)
  Forall :: Integer -> [ProxyArg] -> SMTExpr Bool -> SMTExpr Bool
  Exists :: Integer -> [ProxyArg] -> SMTExpr Bool -> SMTExpr Bool
  Let :: Integer -> [SMTExpr Untyped] -> SMTExpr b -> SMTExpr b
  App :: (Args arg,SMTType res) => SMTFunction arg res -> arg -> SMTExpr res
  Named :: SMTExpr a -> Integer -> SMTExpr a
  InternalObj :: (SMTType t,Typeable a,Ord a,Show a) => a -> SMTAnnotation t -> SMTExpr t
  UntypedExpr :: SMTType t => SMTExpr t -> SMTExpr Untyped
  UntypedExprValue :: SMTValue t => SMTExpr t -> SMTExpr UntypedValue
  deriving Typeable

data Sort' a = BoolSort
             | IntSort
             | RealSort
             | BVSort { bvSortWidth :: Integer
                      , bvSortUntyped :: Bool }
             | ArraySort [a] a
             | NamedSort String [a]
             deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

type Sort = Fix Sort'

data Value = BoolValue Bool
           | IntValue Integer
           | RealValue (Ratio Integer)
           | BVValue { bvValueWidth :: Integer
                     , bvValueValue :: Integer }
           | ConstrValue String [Value] (Maybe (String,[Sort]))
           deriving (Eq,Ord,Show)

data SMTFunction arg res where
  SMTEq :: SMTType a => SMTFunction [SMTExpr a] Bool
  SMTMap :: (Liftable arg,SMTType res,Args i) => SMTFunction arg res -> SMTFunction (Lifted arg i) (SMTArray i res)
  SMTFun :: (Args arg,SMTType res) => Integer -> SMTAnnotation res -> SMTFunction arg res
  SMTBuiltIn :: (Liftable arg,SMTType res) => String -> SMTAnnotation res -> SMTFunction arg res
  SMTOrd :: (SMTType a) => SMTOrdOp -> SMTFunction (SMTExpr a,SMTExpr a) Bool
  SMTArith :: (SMTType a,Num a) => SMTArithOp -> SMTFunction [SMTExpr a] a
  SMTMinus :: (SMTType a,Num a) => SMTFunction (SMTExpr a,SMTExpr a) a
  SMTIntArith :: SMTIntArithOp -> SMTFunction (SMTExpr Integer,SMTExpr Integer) Integer
  SMTDivide :: SMTFunction (SMTExpr Rational,SMTExpr Rational) Rational
  SMTNeg :: (SMTType a,Num a) => SMTFunction (SMTExpr a) a
  SMTAbs :: (SMTType a,Num a) => SMTFunction (SMTExpr a) a
  SMTNot :: SMTFunction (SMTExpr Bool) Bool
  SMTLogic :: SMTLogicOp -> SMTFunction [SMTExpr Bool] Bool
  SMTDistinct :: SMTType a => SMTFunction [SMTExpr a] Bool
  SMTToReal :: SMTFunction (SMTExpr Integer) Rational
  SMTToInt :: SMTFunction (SMTExpr Rational) Integer
  SMTITE :: SMTType a => SMTFunction (SMTExpr Bool,SMTExpr a,SMTExpr a) a
  SMTBVComp :: IsBitVector a => SMTBVCompOp -> SMTFunction (SMTExpr (BitVector a),SMTExpr (BitVector a)) Bool
  SMTBVBin :: IsBitVector a => SMTBVBinOp -> SMTFunction (SMTExpr (BitVector a),SMTExpr (BitVector a)) (BitVector a)
  SMTBVUn :: IsBitVector a => SMTBVUnOp -> SMTFunction (SMTExpr (BitVector a)) (BitVector a)
  SMTSelect :: (Liftable i,SMTType v) => SMTFunction (SMTExpr (SMTArray i v),i) v
  SMTStore :: (Liftable i,SMTType v) => SMTFunction (SMTExpr (SMTArray i v),i,SMTExpr v) (SMTArray i v)
  SMTConstArray :: (Args i,SMTType v) => ArgAnnotation i -> SMTFunction (SMTExpr v) (SMTArray i v)
  SMTConcat :: (Concatable a b) => SMTFunction (SMTExpr (BitVector a),SMTExpr (BitVector b)) (BitVector (ConcatResult a b))
  SMTExtract :: (TypeableNat start,TypeableNat len,
                 Extractable from len')
                => Proxy start -> Proxy len -> SMTFunction (SMTExpr (BitVector from)) (BitVector len')
  SMTConstructor :: (Args arg,SMTType dt) => Constructor arg dt -> SMTFunction arg dt
  SMTConTest :: (Args arg,SMTType dt) => Constructor arg dt -> SMTFunction (SMTExpr dt) Bool
  SMTFieldSel :: (SMTType a,SMTType f) => Field a f -> SMTFunction (SMTExpr a) f
  SMTDivisible :: Integer -> SMTFunction (SMTExpr Integer) Bool
  deriving (Typeable)

class (SMTValue (BitVector a)) => IsBitVector a where
  getBVSize :: Proxy a -> SMTAnnotation (BitVector a) -> Integer

class (IsBitVector a,IsBitVector b,IsBitVector (ConcatResult a b))
      => Concatable a b where
  type ConcatResult a b
  concatAnnotation :: a -> b
                      -> SMTAnnotation (BitVector a)
                      -> SMTAnnotation (BitVector b)
                      -> SMTAnnotation (BitVector (ConcatResult a b))

class (IsBitVector a,IsBitVector b) => Extractable a b where
  extractAnn :: a -> b -> Integer -> SMTAnnotation (BitVector a) -> SMTAnnotation (BitVector b)
  getExtractLen :: a -> b -> SMTAnnotation (BitVector b) -> Integer

-- | Represents a constructor of a datatype /a/
--   Can be obtained by using the template haskell extension module
data Constructor arg res = Constructor [ProxyArg] DataType Constr deriving (Typeable)

-- | Represents a field of the datatype /a/ of the type /f/
data Field a f = Field [ProxyArg] DataType Constr DataField deriving (Typeable)

newtype InterpolationGroup = InterpolationGroup Integer deriving (Typeable,Eq,Ord,Show)

-- | Identifies a clause in an unsatisfiable core
newtype ClauseId = ClauseId Integer deriving (Typeable,Eq,Ord,Show)

-- | Options controling the behaviour of the SMT solver
data SMTOption
     = PrintSuccess Bool -- ^ Whether or not to print \"success\" after each operation
     | ProduceModels Bool -- ^ Produce a satisfying assignment after each successful checkSat
     | ProduceProofs Bool -- ^ Produce a proof of unsatisfiability after each failed checkSat
     | ProduceUnsatCores Bool -- ^ Enable the querying of unsatisfiable cores after a failed checkSat
     | ProduceInterpolants Bool -- ^ Enable the generation of craig interpolants
     deriving (Show,Eq,Ord)

data SMTInfo i where
  SMTSolverName :: SMTInfo String
  SMTSolverVersion :: SMTInfo String

-- | Instances of this class may be used as arguments for constructed functions and quantifiers.
class (Ord a,Typeable a,Show a,
       Ord (ArgAnnotation a),Typeable (ArgAnnotation a),Show (ArgAnnotation a))
      => Args a where
  type ArgAnnotation a
  foldExprs :: Monad m => (forall t. SMTType t => s -> SMTExpr t -> SMTAnnotation t -> m (s,SMTExpr t))
            -> s -> a -> ArgAnnotation a -> m (s,a)
  foldExprs f s x ann = do
    (s',_,r) <- foldsExprs (\cs [(expr,_)] ann' -> do
                               (cs',cr) <- f cs expr ann'
                               return (cs',[cr],cr)
                           ) s [(x,())] ann
    return (s',r)
  foldsExprs :: Monad m => (forall t. SMTType t => s -> [(SMTExpr t,b)] -> SMTAnnotation t -> m (s,[SMTExpr t],SMTExpr t))
                -> s -> [(a,b)] -> ArgAnnotation a -> m (s,[a],a)
  extractArgAnnotation :: a -> ArgAnnotation a
  toArgs :: ArgAnnotation a -> [SMTExpr Untyped] -> Maybe (a,[SMTExpr Untyped])
  
  fromArgs :: a -> [SMTExpr Untyped]
  fromArgs arg = fst $ foldExprsId (\lst expr ann -> (lst++[UntypedExpr expr],expr)
                                   ) [] arg (extractArgAnnotation arg)
  getTypes :: a -> ArgAnnotation a -> [ProxyArg]
  getArgAnnotation :: a -> [Sort] -> (ArgAnnotation a,[Sort])

getSorts :: Args a => a -> ArgAnnotation a -> [Sort]
getSorts u ann = fmap (\prx -> withProxyArg prx getSort) (getTypes u ann)

instance Args () where
  type ArgAnnotation () = ()
  foldExprs _ s _ _ = return (s,())
  foldsExprs _ s args _ = return (s,fmap (const ()) args,())
  extractArgAnnotation _ = ()
  toArgs _ x = Just ((),x)
  fromArgs _ = []
  getTypes _ _ = []
  getArgAnnotation _ xs = ((),xs)

foldExprsId :: Args a => (forall t. SMTType t => s -> SMTExpr t -> SMTAnnotation t -> (s,SMTExpr t))
               -> s -> a -> ArgAnnotation a -> (s,a)
foldExprsId f st arg ann = runIdentity $ foldExprs (\st' expr ann' -> return $ f st' expr ann') st arg ann

foldsExprsId :: Args a => (forall t. SMTType t => s -> [(SMTExpr t,b)] -> SMTAnnotation t -> (s,[SMTExpr t],SMTExpr t))
               -> s -> [(a,b)] -> ArgAnnotation a -> (s,[a],a)
foldsExprsId f st exprs anns = runIdentity $ foldsExprs (\st' exprs' anns' -> return $ f st' exprs' anns'
                                                        ) st exprs anns

class (Args a) => Liftable a where
  type Lifted a i
  getLiftedArgumentAnn :: a -> i -> ArgAnnotation a -> ArgAnnotation i -> ArgAnnotation (Lifted a i)
  inferLiftedAnnotation :: a -> i -> ArgAnnotation (Lifted a i) -> (ArgAnnotation i,ArgAnnotation a)
#ifdef SMTLIB2_WITH_CONSTRAINTS
  getConstraint :: Args i => p (a,i) -> Dict (Liftable (Lifted a i))
#endif

argSorts :: Args a => a -> ArgAnnotation a -> [Sort]
argSorts arg ann = Prelude.reverse res
    where
      (res,_) = foldExprsId (\tps e ann' -> ((getSort (getUndef e) ann'):tps,e)) [] arg ann

unpackArgs :: Args a => (forall t. SMTType t => SMTExpr t -> SMTAnnotation t -> s -> (c,s)) -> a -> ArgAnnotation a -> s -> ([c],s)
unpackArgs f x ann i = fst $ foldExprsId (\(res,ci) e ann' -> let (p,ni) = f e ann' ci
                                                              in ((res++[p],ni),e)
                                         ) ([],i) x ann

-- | An extension of the `Args` class: Instances of this class can be represented as native haskell data types.
class Args a => LiftArgs a where
  type Unpacked a
  -- | Converts a haskell value into its SMT representation.
  liftArgs :: Unpacked a -> ArgAnnotation a -> a
  -- | Converts a SMT representation back into a haskell value.
  unliftArgs :: Monad m => a -> (forall t. SMTValue t => SMTExpr t -> m t) -> m (Unpacked a)

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust ((Just x):_) = Just x
firstJust (Nothing:xs) = firstJust xs

getUndef :: SMTExpr t -> t
getUndef _ = error "Don't evaluate the result of 'getUndef'"

getFunUndef :: SMTFunction arg res -> (arg,res)
getFunUndef _ = (error "Don't evaluate the first result of 'getFunUndef'",
                 error "Don't evaluate the second result of 'getFunUndef'")

getArrayUndef :: Args i => SMTExpr (SMTArray i v) -> (i,Unpacked i,v)
getArrayUndef _ = (undefined,undefined,undefined)

withSMTBackendExitCleanly :: SMTBackend b IO => b -> SMT a -> IO a
withSMTBackendExitCleanly backend act
  = bracket
    (return backend)
    (\backend -> smtHandle backend SMTExit)
    (\backend -> withSMTBackend' backend False act)

withSMTBackend :: SMTBackend a m => a -> SMT' m b -> m b
withSMTBackend b = withSMTBackend' b True

withSMTBackend' :: SMTBackend a m => a -> Bool -> SMT' m b -> m b
withSMTBackend' backend mustExit f = do
  (res,nbackend) <- runSMT f backend
  when mustExit (smtHandle nbackend SMTExit >> return ())
  return res

funInfoSort :: FunInfo -> Sort
funInfoSort (FunInfo { funInfoProxy = _::Proxy (a,t)
                     , funInfoResAnn = ann})
  = getSort (undefined::t) ann

funInfoArgSorts :: FunInfo -> [Sort]
funInfoArgSorts (FunInfo { funInfoProxy = _::Proxy (a,t)
                         , funInfoArgAnn = ann })
  = getSorts (undefined::a) ann

{-newVariableId :: (Monad m) => Maybe String -> (Integer -> Maybe Integer -> (r,FunInfo)) -> SMT' m r
newVariableId name f = do
  st <- getSMT
  let idx = nextVar st
      (nc,st') = case name of
        Nothing -> (Nothing,st)
        Just name' -> let nc = Map.findWithDefault 0 name' (nameCount st)
                      in (Just nc,st { namedVars = Map.insert (name',nc) idx (namedVars st)
                                     , nameCount = Map.insert name' (nc+1) (nameCount st) })
      (res,info) = f idx nc
  putSMT $ st' { nextVar = succ idx
               , allVars = Map.insert idx info (allVars st') }
  return res

newVariable :: (Monad m,SMTType t) => Maybe String -> SMTAnnotation t -> SMT' m (SMTExpr t,FunInfo)
newVariable name (ann::SMTAnnotation t)
  = newVariableId name
    (\idx nc -> let info = FunInfo { funInfoId = idx
                                   , funInfoProxy = Proxy :: Proxy ((),t)
                                   , funInfoArgAnn = ()
                                   , funInfoResAnn = ann
                                   , funInfoName = case (name,nc) of
                                     (Nothing,Nothing) -> Nothing
                                     (Just name',Just nc') -> Just (name',nc') }
                in ((Var idx ann::SMTExpr t,info),info))

newFunction :: (Monad m,Args arg,SMTType r) => Maybe String -> ArgAnnotation arg -> SMTAnnotation r -> SMT' m (SMTFunction arg r,FunInfo)
newFunction name (ann_arg::ArgAnnotation arg) (ann_res::SMTAnnotation r)
  = newVariableId name
    (\idx nc -> let info = FunInfo { funInfoId = idx
                                   , funInfoProxy = Proxy :: Proxy (arg,r)
                                   , funInfoArgAnn = ann_arg
                                   , funInfoResAnn = ann_res
                                   , funInfoName = case (name,nc) of
                                     (Nothing,Nothing) -> Nothing
                                     (Just name',Just nc') -> Just (name',nc') }
                in ((SMTFun idx ann_res::SMTFunction arg r,info),info))

createArgs :: Args a => ArgAnnotation a -> Integer -> Map Integer FunInfo -> (a,[FunInfo],Integer,Map Integer FunInfo)
createArgs ann i mp
  = let ((tps,ni,nmp),res)
          = foldExprsId (\(tps',ci,mp') (_::SMTExpr t) ann'
                         -> let info = FunInfo { funInfoId = ci
                                               , funInfoProxy = Proxy :: Proxy ((),t)
                                               , funInfoArgAnn = ()
                                               , funInfoResAnn = ann'
                                               , funInfoName = Nothing }
                            in ((tps'++[info],ci+1,Map.insert ci info mp'),Var ci ann')
                        ) ([],i,mp) (error "Evaluated the argument to createArgs") ann
    in (res,tps,ni,nmp)

createArgs' :: (Args a,Monad m) => ArgAnnotation a -> SMT' m (a,[FunInfo])
createArgs' ann = do
  (tps,res) <- foldExprs (\tps' (_::SMTExpr t) ann' -> do
                             (expr',info) <- newVariable Nothing ann'
                             return (tps'++[info],expr')
                         ) [] (error "Evaluated the argument to createArgs") ann
  return (res,tps)

nameVariable :: Monad m => Integer -> String -> SMT' m ()
nameVariable var name = do
  st <- getSMT
  let c = Map.findWithDefault 0 name (nameCount st)
  putSMT $ st { nameCount = Map.insert name (c+1) (nameCount st) }-}

argsSignature :: Args a => a -> ArgAnnotation a -> [Sort]
argsSignature arg ann
  = reverse $ fst $
    foldExprsId (\sigs e ann' -> ((getSort (getUndef e) ann'):sigs,e))
    [] arg ann

{-
functionGetSignature :: (SMTFunction f)
                        => f
                        -> ArgAnnotation (SMTFunArg f)
                        -> SMTAnnotation (SMTFunRes f)
                        -> ([Sort],Sort)
functionGetSignature fun arg_ann res_ann
  = let ~(uarg,ures) = getFunUndef fun
    in (argsSignature uarg arg_ann,getSort ures res_ann)-}

{-
getSortParser :: Monad m => SMT' m SortParser
getSortParser = do
  st <- getSMT
  return $ mconcat $ fmap (withDeclaredType (\u _ -> fromSort u)) (Map.elems $ declaredTyCons st)
-}

argumentSortToSort :: Monad m => (Integer -> m Sort) -> ArgumentSort -> m Sort
argumentSortToSort f (Fix (ArgumentSort i)) = f i
argumentSortToSort f (Fix (NormalSort s)) = do
  res <- mapM (argumentSortToSort f) s
  return (Fix res)

sortToArgumentSort :: Sort -> ArgumentSort
sortToArgumentSort (Fix s) = Fix (NormalSort (fmap sortToArgumentSort s))

declareType :: (Monad m,SMTType t) => t -> SMTAnnotation t -> SMT' m ()
declareType (_::t) ann = smtBackend $ \b0 -> do
  (dts,b1) <- smtHandle b0 SMTDeclaredDataTypes
  let (colls,ndts) = getNewTypeCollections (Proxy::Proxy t) ann dts
  b2 <- foldlM (\backend coll -> do
                   ((),nbackend) <- smtHandle backend (SMTDeclareDataTypes coll)
                   return nbackend
               ) b1 colls
  return ((),b2)

-- Data type info

data DataTypeInfo = DataTypeInfo { structures :: [TypeCollection]
                                 , datatypes :: Map String (DataType,TypeCollection)
                                 , constructors :: Map String (Constr,DataType,TypeCollection)
                                 , fields :: Map String (DataField,Constr,DataType,TypeCollection) }
                  deriving Typeable

data TypeCollection = TypeCollection { argCount :: Integer
                                     , dataTypes :: [DataType]
                                     }

data ProxyArg = forall t. SMTType t => ProxyArg t (SMTAnnotation t) deriving Typeable

data ProxyArgValue = forall t. SMTValue t => ProxyArgValue t (SMTAnnotation t) deriving Typeable

withProxyArg :: ProxyArg -> (forall t. SMTType t => t -> SMTAnnotation t -> a) -> a
withProxyArg (ProxyArg x ann) f = f x ann

withProxyArgValue :: ProxyArgValue -> (forall t. SMTValue t => t -> SMTAnnotation t -> a) -> a
withProxyArgValue (ProxyArgValue x ann) f = f x ann

instance Show ProxyArg where
  showsPrec p (ProxyArg u ann) = showParen (p>10) $
                                 showString "ProxyArg " .
                                 showsPrec 11 (typeOf u) .
                                 showChar ' ' .
                                 showsPrec 11 ann

instance Eq ProxyArg where
  (ProxyArg (u1::t) ann1) == (ProxyArg u2 ann2) = case cast (u2,ann2) of
    Just (_::t,ann2') -> ann1==ann2'
    Nothing -> False

instance Ord ProxyArg where
  compare (ProxyArg u1 ann1) (ProxyArg u2 ann2) = case compare (typeOf u1) (typeOf u2) of
    EQ -> case cast ann2 of
      Just ann2' -> compare ann1 ann2'
    x -> x

instance Show ProxyArgValue where
  showsPrec p (ProxyArgValue u ann) = showParen (p>10) $
                                      showString "ProxyArg " .
                                      showsPrec 11 (typeOf u) .
                                      showChar ' ' .
                                      showsPrec 11 ann

instance Eq ProxyArgValue where
  (ProxyArgValue (u1::t) ann1) == (ProxyArgValue u2 ann2) = case cast (u2,ann2) of
    Just (_::t,ann2') -> ann1==ann2'
    Nothing -> False

instance Ord ProxyArgValue where
  compare (ProxyArgValue u1 ann1) (ProxyArgValue u2 ann2) = case compare (typeOf u1) (typeOf u2) of
    EQ -> case cast ann2 of
      Just ann2' -> compare ann1 ann2'
    x -> x

data AnyValue = forall t. SMTType t => AnyValue [ProxyArg] t (SMTAnnotation t)

withAnyValue :: AnyValue -> (forall t. SMTType t => [ProxyArg] -> t -> SMTAnnotation t -> a) -> a
withAnyValue (AnyValue p x ann) f = f p x ann

castAnyValue :: SMTType t => AnyValue -> Maybe (t,SMTAnnotation t)
castAnyValue (AnyValue _ x ann) = cast (x,ann)

data DataType = DataType { dataTypeName :: String
                         , dataTypeConstructors :: [Constr]
                         , dataTypeGetUndefined
                           :: forall r. [ProxyArg]
                              -> (forall t. SMTType t => t -> SMTAnnotation t -> r)
                              -> r
                         }

data Constr = Constr { conName :: String
                     , conFields :: [DataField]
                     , construct :: forall r. [Maybe ProxyArg] -> [AnyValue]
                                    -> (forall t. SMTType t => [ProxyArg] -> t -> SMTAnnotation t -> r)
                                    -> r
                     , conUndefinedArgs :: forall r. [ProxyArg] -> (forall arg. Args arg => arg -> ArgAnnotation arg -> r) -> r
                     , conTest :: forall t. SMTType t => [ProxyArg] -> t -> Bool
                     }

data DataField = DataField { fieldName :: String
                           , fieldSort :: ArgumentSort
                           , fieldGet :: forall r t. SMTType t => [ProxyArg] -> t
                                         -> (forall f. SMTType f => f -> SMTAnnotation f -> r)
                                         -> r
                           }

emptyDataTypeInfo :: DataTypeInfo
emptyDataTypeInfo = DataTypeInfo { structures = []
                                 , datatypes = Map.empty
                                 , constructors = Map.empty
                                 , fields = Map.empty }

containsTypeCollection :: TypeCollection -> DataTypeInfo -> Bool
containsTypeCollection struct dts = case dataTypes struct of
  dt:_ -> Map.member (dataTypeName dt) (datatypes dts)
  [] -> False

addDataTypeStructure :: TypeCollection -> DataTypeInfo -> DataTypeInfo
addDataTypeStructure struct dts
  = foldl (\cdts dt
            -> foldl (\cdts con
                      -> foldl (\cdts field
                                -> cdts { fields = Map.insert (fieldName field) (field,con,dt,struct) (fields cdts) }
                               ) (cdts { constructors = Map.insert (conName con) (con,dt,struct) (constructors cdts) })
                         (conFields con)
                     ) (cdts { datatypes = Map.insert (dataTypeName dt) (dt,struct) (datatypes cdts) })
               (dataTypeConstructors dt)
          ) (dts { structures = struct:(structures dts) }) (dataTypes struct)

-- | Get all the type collections which are not yet declared from a type.
getNewTypeCollections :: SMTType t => Proxy t -> SMTAnnotation t -> DataTypeInfo
                         -> ([TypeCollection],DataTypeInfo)
getNewTypeCollections (_::Proxy t) ann dts
  = case asDataType (undefined::t) ann of
    Nothing -> ([],dts) -- This is no declarable data type
    Just (name,coll)
      -> let isKnown = Map.member name (datatypes dts) -- Is the datatype already known?
             proxies = getProxyArgs (undefined::t) ann
             (tps1,dts1) = if isKnown
                           then ([],dts)
                           else ([coll],addDataTypeStructure coll dts)
             (tps2,dts2) = foldl (\(tps,dts) prx -- Check all the data type parameters
                                  -> withProxyArg prx $
                                     \(_::a) ann'
                                     -> let (ntps,ndts) = getNewTypeCollections
                                                          (Proxy::Proxy a)
                                                          ann' dts
                                        in (ntps++tps,ndts)
                                 ) ([],dts1) proxies
             (tps3,dts3) = if isKnown
                           then ([],dts2)
                           else foldl
                                (\cur dt
                                 -> dataTypeGetUndefined dt proxies $
                                    \dtUndef dtAnn
                                    -> foldl
                                       (\cur con
                                        -> foldl
                                           (\(tps,dts) field
                                            -> fieldGet field proxies dtUndef $
                                               \(_::f) fAnn
                                               -> let (ntps,ndts) = getNewTypeCollections
                                                                    (Proxy::Proxy f)
                                                                    fAnn dts
                                                  in (ntps++tps,ndts)
                                           ) cur (conFields con)
                                       ) cur (dataTypeConstructors dt)
                                ) ([],dts2) (dataTypes coll) -- Declare all field types
         in (tps2++tps3++tps1,dts3)

asNamedSort :: Sort -> Maybe (String,[Sort])
asNamedSort (Fix (NamedSort name args)) = Just (name,args)
asNamedSort _ = Nothing

escapeName :: Either (String,Integer) Integer -> String
escapeName (Right i) = "var"++(if i==0
                              then ""
                              else "_"++show i)
escapeName (Left (c:cs,nc))
  = (if isDigit c
     then "num"++escapeName' (c:cs)
     else escapeName' (c:cs))++(if nc==0
                                then ""
                                else "_"++show nc)
escapeName (Left ([],0)) = "no_name"
escapeName (Left ([],n)) = "no_name"++show n

escapeName' :: String -> String
escapeName' [] = []
escapeName' ('_':xs) = '_':'_':escapeName' xs
escapeName' (x:xs) = x:escapeName' xs

unescapeName :: String -> Maybe (Either (String,Integer) Integer)
unescapeName "var" = Just (Right 0)
unescapeName ('v':'a':'r':'_':rest) = if all isDigit rest
                                      then Just (Right (read rest))
                                      else Nothing
unescapeName xs = do
  res <- unescapeName' xs
  return $ Left res

unescapeName' :: String -> Maybe (String,Integer)
unescapeName' ('n':'o':'_':'n':'a':'m':'e':rest) = case rest of
  [] -> Just ("",0)
  xs -> if all isDigit xs
        then Just ("",read xs)
        else Nothing
unescapeName' ('_':'_':rest) = do
  (name,nc) <- unescapeName' rest
  return ('_':name,nc)
unescapeName' ('_':rest) = if all isDigit rest
                           then return ("",read rest)
                           else Nothing
unescapeName' (x:xs) = do
  (name,nc) <- unescapeName' xs
  return (x:name,nc)
unescapeName' "" = Just ("",0)

data SMTState = SMTState { nextVar :: Integer
                         , nextInterpolationGroup :: Integer
                         , nextClauseId :: Integer
                         , allVars :: Map Integer (FunInfo,Integer)
                         , namedVars :: Map (String,Integer) Integer
                         , nameCount :: Map String Integer
                         , declaredDataTypes :: DataTypeInfo }

emptySMTState :: SMTState
emptySMTState = SMTState { nextVar = 0
                         , nextInterpolationGroup = 0
                         , nextClauseId = 0
                         , allVars = Map.empty
                         , namedVars = Map.empty
                         , nameCount = Map.empty
                         , declaredDataTypes = emptyDataTypeInfo
                         }

smtStateAddFun :: FunInfo -> SMTState -> (Integer,String,SMTState)
smtStateAddFun finfo st
  = (v,name',nst)
  where
    v = nextVar st
    nameBase = case funInfoName finfo of
      Nothing -> "var"
      Just n -> n
    nc = case Map.lookup nameBase (nameCount st) of
      Just n -> n
      Nothing -> 0
    name' = if nc==0
            then nameBase
            else nameBase++"_"++show nc
    nst = st { nextVar = v+1
             , allVars = Map.insert v (finfo,nc) (allVars st)
             , namedVars = Map.insert (nameBase,nc) v (namedVars st)
             , nameCount = Map.insert nameBase (nc+1) (nameCount st)
             }

-- BitVectors

#ifdef SMTLIB2_WITH_DATAKINDS
data Nat = Z | S Nat deriving Typeable

data BVKind = BVUntyped
            | BVTyped Nat

class TypeableNat n where
  typeOfNat :: Proxy n -> TypeRep
  typeOfNat p = foldl
                (\c _ -> mkTyConApp (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'S") [c])
                (mkTyConApp (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'Z") [])
                (genericReplicate (reflectNat p 0) ())
  reflectNat :: Proxy n -> Integer -> Integer

instance TypeableNat Z where
  typeOfNat _ = mkTyConApp
                (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'Z")
                []
  reflectNat _ x = x

instance TypeableNat n => TypeableNat (S n) where
  typeOfNat _ = mkTyConApp
                (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'S")
                [typeOfNat (Proxy::Proxy n)]
  reflectNat _ x = reflectNat (Proxy::Proxy n) (x+1)

class TypeableBVKind n where
  typeOfBVKind :: Proxy n -> TypeRep

instance TypeableBVKind BVUntyped where
  typeOfBVKind _ = mkTyConApp
                   (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'BVUntyped")
                   []

instance TypeableNat n => TypeableBVKind (BVTyped n) where
  typeOfBVKind _ = mkTyConApp
                   (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "'BVTyped")
                   [typeOfNat (Proxy::Proxy n)]

type family Add (n1 :: Nat) (n2 :: Nat) :: Nat
type instance Add Z n = n
type instance Add (S n1) n2 = S (Add n1 n2)

reifySum :: (Num a,Ord a) => a -> a -> (forall n1 n2. (TypeableNat n1,TypeableNat n2,TypeableNat (Add n1 n2))
                                        => Proxy (n1::Nat) -> Proxy (n2::Nat) -> Proxy (Add n1 n2) -> r) -> r
reifySum n1 n2 f
  | n1 < 0 || n2 < 0 = error "smtlib2: Cann only reify numbers >= 0."
  | otherwise = reifySum' n1 n2 f
  where
    reifySum' :: (Num a,Ord a) => a -> a
                 -> (forall n1 n2. (TypeableNat n1,TypeableNat n2,TypeableNat (Add n1 n2))
                     => Proxy (n1::Nat) -> Proxy (n2::Nat) -> Proxy (Add n1 n2) -> r) -> r
    reifySum' 0 n2 f = reifyNat n2 $ \(_::Proxy i) -> f (Proxy::Proxy Z) (Proxy::Proxy i) (Proxy::Proxy i)
    reifySum' n1 n2 f = reifySum' (n1-1) n2 $ \(_::Proxy i1) (_::Proxy i2) (_::Proxy i3)
                                               -> f (Proxy::Proxy (S i1)) (Proxy::Proxy i2) (Proxy::Proxy (S i3))

reifyExtract :: (Num a,Ord a) => a -> a -> a
                -> (forall n1 n2 n3 n4. (TypeableNat n1,TypeableNat n2,TypeableNat n3,TypeableNat n4,Add n4 n2 ~ S n3)
                    => Proxy (n1::Nat) -> Proxy (n2::Nat) -> Proxy (n3::Nat) -> Proxy (n4::Nat) -> r) -> r
reifyExtract t l u f
  | t <= u || l > u || l < 0 = error "smtlib2: Invalid extract parameters."
  | otherwise = reifyExtract' t l u (u - l + 1) f
  where
    reifyExtract' :: (Num a,Ord a) => a -> a -> a -> a
                     -> (forall n1 n2 n3 n4. (TypeableNat n1,TypeableNat n2,TypeableNat n3,TypeableNat n4,Add n4 n2 ~ S n3)
                         => Proxy (n1::Nat) -> Proxy (n2::Nat) -> Proxy (n3::Nat) -> Proxy (n4::Nat) -> r) -> r
    reifyExtract' t 0 0 1 f
      = reifyNat t $
        \(_::Proxy n1) -> f (Proxy::Proxy n1) (Proxy::Proxy Z) (Proxy::Proxy Z) (Proxy::Proxy (S Z))
    reifyExtract' t l u 0 f
      = reifyNat t $
        \(_::Proxy n1)
        -> reifyNat u $
           \(_::Proxy n3)
           -> f (Proxy::Proxy n1) (Proxy::Proxy (S n3)) (Proxy::Proxy n3) (Proxy::Proxy Z)
    reifyExtract' t l u r f = reifyExtract' t l (u-1) (r-1) $
                              \(_::Proxy n1) (_::Proxy n2) (_::Proxy n3) (_::Proxy n4)
                               -> f (Proxy::Proxy n1) (Proxy::Proxy n2) (Proxy::Proxy (S n3)) (Proxy::Proxy (S n4))


reifyNat :: (Num a,Ord a) => a -> (forall n. TypeableNat n => Proxy (n::Nat) -> r) -> r
reifyNat x f
  | x < 0 = error "smtlib2: Can only reify numbers >= 0."
  | otherwise = reifyNat' x f
  where
    reifyNat' :: (Num a,Ord a) => a -> (forall n. TypeableNat n => Proxy (n::Nat) -> r) -> r
    reifyNat' 0 f = f (Proxy :: Proxy Z)
    reifyNat' n f = reifyNat' (n-1) (\(_::Proxy n) -> f (Proxy::Proxy (S n)))

data BitVector (b :: BVKind) = BitVector Integer deriving (Eq,Ord,Typeable)

instance TypeableBVKind k => Typeable (BitVector k) where
  typeOf _ = mkTyConApp
             (mkTyCon3 "smtlib2" "Language.SMTLib2.Internals" "BitVector")
             [typeOfBVKind (Proxy::Proxy k)]
#else
data Z = Z deriving (Typeable)
data S a = S deriving (Typeable)

class Typeable a => TypeableNat a where
  reflectNat :: Proxy a -> Integer -> Integer

instance TypeableNat Z where
  reflectNat _ = id

instance TypeableNat n => TypeableNat (S n) where
  reflectNat _ x = reflectNat (Proxy::Proxy n) (x+1)

type family Add n1 n2
type instance Add Z n = n
type instance Add (S n1) n2 = S (Add n1 n2)

data BVUntyped = BVUntyped deriving (Eq,Ord,Show,Typeable)
data BVTyped n = BVTyped deriving (Eq,Ord,Show,Typeable)

reifyNat :: (Num a,Ord a) => a -> (forall n. TypeableNat n => Proxy n -> r) -> r
reifyNat n f
  | n < 0 = error "smtlib2: Can only reify numbers >= 0."
  | otherwise = reifyNat' n f
  where
    reifyNat' :: (Num a,Eq a) => a -> (forall n. TypeableNat n => Proxy n -> r) -> r
    reifyNat' 0 f' = f' (Proxy::Proxy Z)
    reifyNat' n' f' = reifyNat' (n'-1) (f'.g)

    g :: Proxy n -> Proxy (S n)
    g _ = Proxy

reifySum :: (Num a,Ord a) => a -> a -> (forall n1 n2. (TypeableNat n1,TypeableNat n2,TypeableNat (Add n1 n2))
                                        => Proxy n1 -> Proxy n2 -> Proxy (Add n1 n2) -> r) -> r
reifySum n1 n2 f
  | n1 < 0 || n2 < 0 = error "smtlib2: Can only reify numbers >= 0."
  | otherwise = reifySum' n1 n2 f
  where
    reifySum' :: (Num a,Ord a) => a -> a
                 -> (forall n1 n2. (TypeableNat n1,TypeableNat n2,TypeableNat (Add n1 n2))
                     => Proxy n1 -> Proxy n2 -> Proxy (Add n1 n2) -> r) -> r
    reifySum' 0 n2' f' = reifyNat n2' $ \(_::Proxy i) -> f' (Proxy::Proxy Z) (Proxy::Proxy i) (Proxy::Proxy i)
    reifySum' n1' n2' f' = reifySum' (n1'-1) n2' $
                           \(_::Proxy i1) (_::Proxy i2) (_::Proxy (Add i1 i2))
                           -> f' (Proxy::Proxy (S i1)) (Proxy::Proxy i2) (Proxy::Proxy (S (Add i1 i2)))

reifyExtract :: (Num a,Ord a) => a -> a -> a
                -> (forall n1 n2 n3 n4. (TypeableNat n1,TypeableNat n2,TypeableNat n3,TypeableNat n4,Add n4 n2 ~ S n3)
                    => Proxy n1 -> Proxy n2 -> Proxy n3 -> Proxy n4 -> r) -> r
reifyExtract t l u f
  | t <= u || l > u || l < 0 = error "smtlib2: Invalid extract parameters."
  | otherwise = reifyExtract' t l u (u - l + 1) f
  where
    reifyExtract' :: (Num a,Ord a) => a -> a -> a -> a
                     -> (forall n1 n2 n3 n4. (TypeableNat n1,TypeableNat n2,TypeableNat n3,TypeableNat n4,Add n4 n2 ~ S n3)
                         => Proxy n1 -> Proxy n2 -> Proxy n3 -> Proxy n4 -> r) -> r
    reifyExtract' t' 0 0  1 f'
      = reifyNat t' $
        \(_::Proxy n1) -> f' (Proxy::Proxy n1) (Proxy::Proxy Z) (Proxy::Proxy Z) (Proxy::Proxy (S Z))
    reifyExtract' t' _ u' 0 f' = reifyNat t' $
                                 \(_::Proxy n1)
                                 -> reifyNat u' $
                                    \(_::Proxy n3)
                                    -> f' (Proxy::Proxy n1) (Proxy::Proxy (S n3)) (Proxy::Proxy n3) (Proxy::Proxy Z)
    reifyExtract' t' l' u' r' f' = reifyExtract' t' l' (u'-1) (r'-1) $
                                   \(_::Proxy n1) (_::Proxy n2) (_::Proxy n3) (_::Proxy n4)
                                   -> f' (Proxy::Proxy n1) (Proxy::Proxy n2) (Proxy::Proxy (S n3)) (Proxy::Proxy (S n4))

data BitVector (b :: *) = BitVector Integer deriving (Eq,Ord,Typeable)
#endif

instance Show (BitVector a) where
  show (BitVector x) = show x

instance Enum (BitVector a) where
  succ (BitVector x) = BitVector (succ x)
  pred (BitVector x) = BitVector (pred x)
  toEnum x = BitVector (toEnum x)
  fromEnum (BitVector x) = fromEnum x
  enumFrom (BitVector x) = [ BitVector y | y <- enumFrom x ]
  enumFromThen (BitVector x) (BitVector y)
    = [ BitVector z | z <- enumFromThen x y ]
  enumFromTo (BitVector x) (BitVector y)
    = [ BitVector z | z <- enumFromTo x y ]
  enumFromThenTo (BitVector x) (BitVector y) (BitVector z)
    = [ BitVector p | p <- enumFromThenTo x y z ]

type N0 = Z
type N1 = S N0
type N2 = S N1
type N3 = S N2
type N4 = S N3
type N5 = S N4
type N6 = S N5
type N7 = S N6
type N8 = S N7
type N9 = S N8
type N10 = S N9
type N11 = S N10
type N12 = S N11
type N13 = S N12
type N14 = S N13
type N15 = S N14
type N16 = S N15
type N17 = S N16
type N18 = S N17
type N19 = S N18
type N20 = S N19
type N21 = S N20
type N22 = S N21
type N23 = S N22
type N24 = S N23
type N25 = S N24
type N26 = S N25
type N27 = S N26
type N28 = S N27
type N29 = S N28
type N30 = S N29
type N31 = S N30
type N32 = S N31
type N33 = S N32
type N34 = S N33
type N35 = S N34
type N36 = S N35
type N37 = S N36
type N38 = S N37
type N39 = S N38
type N40 = S N39
type N41 = S N40
type N42 = S N41
type N43 = S N42
type N44 = S N43
type N45 = S N44
type N46 = S N45
type N47 = S N46
type N48 = S N47
type N49 = S N48
type N50 = S N49
type N51 = S N50
type N52 = S N51
type N53 = S N52
type N54 = S N53
type N55 = S N54
type N56 = S N55
type N57 = S N56
type N58 = S N57
type N59 = S N58
type N60 = S N59
type N61 = S N60
type N62 = S N61
type N63 = S N62
type N64 = S N63

type BV8 = BitVector (BVTyped N8)
type BV16 = BitVector (BVTyped N16)
type BV32 = BitVector (BVTyped N32)
type BV64 = BitVector (BVTyped N64)

instance Monad m => SMTBackend (AnyBackend m) m where
  smtHandle (AnyBackend b) req = do
    (res,nb) <- smtHandle b req
    return (res,AnyBackend nb)
  smtGetNames (AnyBackend b) = smtGetNames b
  smtNextName (AnyBackend b) = smtNextName b

instance Show (SMTExpr t) where
  showsPrec = showExpr

newtype Bound = Bound Integer deriving (Typeable,Eq,Ord,Show)

showExpr :: Int -> SMTExpr t -> ShowS
showExpr p (Var v ann) = showParen (p>10) (showString "Var " .
                                           showsPrec 11 v .
                                           showChar ' ' .
                                           showsPrec 11 ann)
showExpr p (QVar lvl v ann) = showParen (p>10) (showString "QVar " .
                                                showsPrec 11 lvl .
                                                showChar ' ' .
                                                showsPrec 11 v .
                                                showChar ' ' .
                                                showsPrec 11 ann)
showExpr p (FunArg v ann) = showParen (p>10) (showString "FunArg " .
                                              showsPrec 11 v .
                                              showChar ' ' .
                                              showsPrec 11 ann)
showExpr p (Const c ann) = showParen (p>10) (showString "Const " .
                                             showsPrec 11 c .
                                             showChar ' ' .
                                             showsPrec 11 ann)
showExpr p (AsArray fun ann) = showParen (p>10) (showString "AsArray " .
                                                 showsPrec 11 fun .
                                                 showChar ' ' .
                                                 showsPrec 11 ann)
showExpr p (Forall lvl args f) = showParen (p>10) (showString "Forall " .
                                                   showsPrec 11 lvl .
                                                   showChar ' ' .
                                                   showsPrec 11 args .
                                                   showString " ~> " .
                                                   showsPrec 11 f)
showExpr p (Exists lvl args f) = showParen (p>10) (showString "Exists " .
                                                   showsPrec 11 lvl .
                                                   showChar ' ' .
                                                   showsPrec 11 args .
                                                   showString " ~> " .
                                                   showsPrec 11 f)
showExpr p (Let lvl arg f) = showParen (p>10) (showString "Let " .
                                               showsPrec 11 lvl .
                                               showChar ' ' .
                                               showsPrec 11 arg .
                                               showChar ' ' .
                                               showsPrec 11 f)
showExpr p (App fun arg) = let strArgs = showsPrec 11 arg
                           in showParen (p>10) (showString "App " .
                                                showsPrec 11 fun .
                                                showChar ' ' .
                                                strArgs)
showExpr p (Named expr i) = let strExpr = showExpr 11 expr
                            in showParen (p>10) (showString "Named " .
                                                 strExpr .
                                                 showChar ' ' .
                                                 showsPrec 11 i)
showExpr p (InternalObj obj ann) = showParen (p>10) (showString "InternalObj " .
                                                     showsPrec 11 obj .
                                                     showChar ' ' .
                                                     showsPrec 11 ann)
showExpr p (UntypedExpr e) = showParen (p>10) (showString "UntypedExpr " .
                                               showExpr 11 e)
showExpr p (UntypedExprValue e) = showParen (p>10) (showString "UntypedExprValue " .
                                                    showExpr 11 e)

instance Show (SMTFunction arg res) where
  showsPrec _ SMTEq = showString "SMTEq"
  showsPrec p (SMTMap fun) = showParen (p>10) (showString "SMTMap " .
                                               showsPrec 11 fun)
  showsPrec p (SMTFun i ann) = showParen (p>10) (showString "SMTFun " .
                                                 showsPrec 11 i .
                                                 showChar ' ' .
                                                 showsPrec 11 ann)
  showsPrec p (SMTBuiltIn name ann) = showParen (p>10) (showString "SMTBuiltIn " .
                                                        showsPrec 11 name .
                                                        showChar ' ' .
                                                        showsPrec 11 ann)
  showsPrec p (SMTOrd op) = showParen (p>10) (showString "SMTOrd " .
                                              showsPrec 11 op)
  showsPrec p (SMTArith op) = showParen (p>10) (showString "SMTArith " .
                                                showsPrec 11 op)
  showsPrec p SMTMinus = showString "SMTMinus"
  showsPrec p (SMTIntArith op) = showParen (p>10) (showString "SMTIntArith " .
                                                   showsPrec 11 op)
  showsPrec p SMTDivide = showString "SMTDivide"
  showsPrec p SMTNeg = showString "SMTNeg"
  showsPrec p SMTAbs = showString "SMTAbs"
  showsPrec p SMTNot = showString "SMTNot"
  showsPrec p (SMTLogic op) = showParen (p>10) (showString "SMTLogic " .
                                                showsPrec 11 op)
  showsPrec p SMTDistinct = showString "SMTDistinct"
  showsPrec p SMTToReal = showString "SMTToReal"
  showsPrec p SMTToInt = showString "SMTToInt"
  showsPrec p SMTITE = showString "SMTITE"
  showsPrec p (SMTBVComp op) = showParen (p>10) (showString "SMTBVComp " .
                                                 showsPrec 11 op)
  showsPrec p (SMTBVBin op) = showParen (p>10) (showString "SMTBVBin " .
                                                showsPrec 11 op)
  showsPrec p (SMTBVUn op) = showParen (p>10) (showString "SMTBVUn " .
                                               showsPrec 11 op)
  showsPrec p SMTSelect = showString "SMTSelect"
  showsPrec p SMTStore = showString "SMTStore"
  showsPrec p (SMTConstArray ann) = showParen (p>10) (showString "SMTConstArray " .
                                                      showsPrec 11 ann)
  showsPrec p SMTConcat = showString "SMTConcat"
  showsPrec p (SMTExtract start len) = showParen (p>10) (showString "SMTExtract " .
                                                         showsPrec 11 (reflectNat start 0) .
                                                         showChar ' ' .
                                                         showsPrec 11 (reflectNat len 0))
  showsPrec p (SMTConstructor con) = showParen (p>10) (showString "SMTConstructor " .
                                                       showsPrec 11 con)
  showsPrec p (SMTConTest con) = showParen (p>10) (showString "SMTConTest " .
                                                   showsPrec 11 con)
  showsPrec p (SMTFieldSel field) = showParen (p>10) (showString "SMTFieldSel " .
                                                      showsPrec 11 field)
  showsPrec p (SMTDivisible i) = showParen (p>10) (showString "SMTDivisible " .
                                                   showsPrec 11 i)

instance Show (Field a f) where
  showsPrec p (Field _ _ _ f) = showParen (p>10)
                                (showString "Field " .
                                 showsPrec 11 (fieldName f))

instance Show (Constructor arg res) where
  showsPrec p (Constructor _ _ con) = showParen (p>10)
                                      (showString "Constructor " .
                                       showsPrec 11 (conName con))

noLimits :: CheckSatLimits
noLimits = CheckSatLimits { limitTime = Nothing
                          , limitMemory = Nothing }

newtype Quantified = Quantified Integer deriving (Typeable,Show,Eq,Ord)

quantificationLevel :: SMTExpr t -> Integer
quantificationLevel (QVar lvl _ _) = lvl+1
quantificationLevel (Forall lvl _ _) = lvl+1
quantificationLevel (Exists lvl _ _) = lvl+1
quantificationLevel (Let lvl _ _) = lvl+1
quantificationLevel (App _ arg) = maximum $ fmap quantificationLevel $ fromArgs arg
quantificationLevel (Named expr _) = quantificationLevel expr
quantificationLevel (UntypedExpr e) = quantificationLevel e
quantificationLevel (UntypedExprValue e) = quantificationLevel e
quantificationLevel _ = 0

inferSorts :: ArgumentSort -> Sort -> Map Integer Sort -> Map Integer Sort
inferSorts (Fix (ArgumentSort i)) s mp = Map.insert i s mp
inferSorts (Fix (NormalSort (ArraySort xs x))) (Fix (ArraySort ys y)) mp
  = foldl (\cmp (x,y) -> inferSorts x y cmp
          ) (inferSorts x y mp) (zip xs ys)
inferSorts (Fix (NormalSort (NamedSort n1 xs))) (Fix (NamedSort n2 ys)) mp
  | n1==n2 = foldl (\cmp (x,y) -> inferSorts x y cmp
                   ) mp (zip xs ys)
inferSorts _ _ mp = mp

valueSort :: DataTypeInfo -> Value -> Sort
valueSort _ (BoolValue _) = Fix BoolSort
valueSort _ (IntValue _) = Fix IntSort
valueSort _ (RealValue _) = Fix RealSort
valueSort _ (BVValue w _) = Fix (BVSort w False)
valueSort dts (ConstrValue _ _ (Just (sname,sargs))) = Fix $ NamedSort sname sargs
valueSort dts (ConstrValue name args Nothing) = case Map.lookup name (constructors dts) of
  Just (con,dt,tc) -> Fix $ NamedSort (dataTypeName dt) (fmap snd $ Map.toAscList infMp)
    where
      argTps = fmap (valueSort dts) args
      conTps = fmap fieldSort (conFields con)
      infMp = foldl (\cinf (tp,argTp) -> inferSorts tp argTp cinf
                    ) Map.empty (zip conTps argTps)
