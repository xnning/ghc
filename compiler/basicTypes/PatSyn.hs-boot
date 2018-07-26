module PatSyn where

import BasicTypes (Arity)
import {-# SOURCE #-} TyCoRep (Type)
import Var (TyCoVar)
import Name (Name)

data PatSyn

patSynArity :: PatSyn -> Arity
patSynInstArgTys :: PatSyn -> [Type] -> [Type]
patSynExTyCoVars :: PatSyn -> [TyCoVar]
patSynName :: PatSyn -> Name
