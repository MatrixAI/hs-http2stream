data CountM a = CountM Int a

instance Monad CountM where
   CountM i x >>= f = f x
