%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnSource]{Main pass of renamer}

\begin{code}
module RnSource ( rnTyClDecl, rnIfaceRuleDecl, rnInstDecl, rnSourceDecls, 
		  rnHsType, rnHsSigType, rnHsTypeFVs, rnHsSigTypeFVs
	) where

#include "HsVersions.h"

import RnExpr
import HsSyn
import HscTypes		( GlobalRdrEnv )
import HsTypes		( hsTyVarNames, pprHsContext )
import RdrName		( RdrName, isRdrDataCon, elemRdrEnv )
import RdrHsSyn		( RdrNameContext, RdrNameHsType, RdrNameConDecl, RdrNameTyClDecl,
			  extractRuleBndrsTyVars, extractHsTyRdrTyVars,
			  extractHsCtxtRdrTyVars, extractGenericPatTyVars
			)
import RnHsSyn
import HsCore

import RnBinds		( rnTopBinds, rnMethodBinds, renameSigs, renameSigsFVs )
import RnEnv		( lookupTopBndrRn, lookupOccRn, newIPName, lookupIfaceName,
			  lookupOrigNames, lookupSysBinder, newLocalsRn,
			  bindLocalsFVRn, 
			  bindTyVarsRn, bindTyVars2Rn,
			  bindTyVarsFV2Rn, extendTyVarEnvFVRn,
			  bindCoreLocalRn, bindCoreLocalsRn, bindLocalNames,
			  checkDupOrQualNames, checkDupNames, mapFvRn
			)
import RnMonad

import Class		( FunDep, DefMeth (..) )
import DataCon		( dataConId )
import Name		( Name, NamedThing(..) )
import NameSet
import PrelInfo		( derivableClassKeys, cCallishClassKeys )
import PrelNames	( deRefStablePtr_RDR, newStablePtr_RDR,
			  bindIO_RDR, returnIO_RDR
			)
import TysWiredIn	( tupleCon )
import List		( partition, nub )
import Outputable
import SrcLoc		( SrcLoc )
import CmdLineOpts	( DynFlag(..) )
				-- Warn of unused for-all'd tyvars
import Unique		( Uniquable(..) )
import Maybes		( maybeToBool )
import ErrUtils		( Message )
import CStrings		( isCLabelString )
import ListSetOps	( removeDupsEq )
\end{code}

@rnSourceDecl@ `renames' declarations.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
(Some of this checking has now been moved to module @TcMonoType@,
since we don't have functional dependency information at this point.)
\item
Checks that all variable occurences are defined.
\item 
Checks the @(..)@ etc constraints in the export list.
\end{enumerate}


%*********************************************************
%*							*
\subsection{Source code declarations}
%*							*
%*********************************************************

\begin{code}
rnSourceDecls :: GlobalRdrEnv -> LocalFixityEnv
	      -> [RdrNameHsDecl] 
	      -> RnMG ([RenamedHsDecl], FreeVars)
	-- The decls get reversed, but that's ok

rnSourceDecls gbl_env local_fixity_env decls
  = initRnMS gbl_env emptyRdrEnv local_fixity_env SourceMode (go emptyFVs [] decls)
  where
	-- Fixity and deprecations have been dealt with already; ignore them
    go fvs ds' []             = returnRn (ds', fvs)
    go fvs ds' (FixD _:ds)    = go fvs ds' ds
    go fvs ds' (DeprecD _:ds) = go fvs ds' ds
    go fvs ds' (d:ds)         = rnSourceDecl d	`thenRn` \(d', fvs') ->
			        go (fvs `plusFV` fvs') (d':ds') ds


rnSourceDecl :: RdrNameHsDecl -> RnMS (RenamedHsDecl, FreeVars)

rnSourceDecl (ValD binds) = rnTopBinds binds	`thenRn` \ (new_binds, fvs) ->
			    returnRn (ValD new_binds, fvs)

rnSourceDecl (TyClD tycl_decl)
  = rnTyClDecl tycl_decl			`thenRn` \ new_decl ->
    finishSourceTyClDecl tycl_decl new_decl	`thenRn` \ (new_decl', fvs) ->
    returnRn (TyClD new_decl', fvs `plusFV` tyClDeclFVs new_decl')

rnSourceDecl (InstD inst)
  = rnInstDecl inst			`thenRn` \ new_inst ->
    finishSourceInstDecl inst new_inst	`thenRn` \ (new_inst', fvs) ->
    returnRn (InstD new_inst', fvs `plusFV` instDeclFVs new_inst')

rnSourceDecl (RuleD rule)
  = rnHsRuleDecl rule		`thenRn` \ (new_rule, fvs) ->
    returnRn (RuleD new_rule, fvs)

rnSourceDecl (DefD (DefaultDecl tys src_loc))
  = pushSrcLocRn src_loc $
    mapFvRn (rnHsTypeFVs doc_str) tys		`thenRn` \ (tys', fvs) ->
    returnRn (DefD (DefaultDecl tys' src_loc), fvs)
  where
    doc_str = text "a `default' declaration"

rnSourceDecl (ForD (ForeignDecl name imp_exp ty ext_nm cconv src_loc))
  = pushSrcLocRn src_loc $
    lookupOccRn name		        `thenRn` \ name' ->
    let 
	extra_fvs FoExport 
	  | isDyn = lookupOrigNames [newStablePtr_RDR, deRefStablePtr_RDR,
				     bindIO_RDR, returnIO_RDR]
	  | otherwise =
		lookupOrigNames [bindIO_RDR, returnIO_RDR] `thenRn` \ fvs ->
		returnRn (addOneFV fvs name')
	extra_fvs other = returnRn emptyFVs
    in
    checkRn (ok_ext_nm ext_nm) (badExtName ext_nm)	`thenRn_`

    extra_fvs imp_exp					`thenRn` \ fvs1 -> 

    rnHsTypeFVs fo_decl_msg ty	       		`thenRn` \ (ty', fvs2) ->
    returnRn (ForD (ForeignDecl name' imp_exp ty' ext_nm cconv src_loc), 
	      fvs1 `plusFV` fvs2)
 where
  fo_decl_msg = ptext SLIT("The foreign declaration for") <+> ppr name
  isDyn	      = isDynamicExtName ext_nm

  ok_ext_nm Dynamic 		   = True
  ok_ext_nm (ExtName nm (Just mb)) = isCLabelString nm && isCLabelString mb
  ok_ext_nm (ExtName nm Nothing)   = isCLabelString nm
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************

\begin{code}
rnInstDecl (InstDecl inst_ty mbinds uprags maybe_dfun_rdr_name src_loc)
	-- Used for both source and interface file decls
  = pushSrcLocRn src_loc $
    rnHsSigType (text "an instance decl") inst_ty	`thenRn` \ inst_ty' ->

    (case maybe_dfun_rdr_name of
	Nothing		   -> returnRn Nothing
	Just dfun_rdr_name -> lookupIfaceName dfun_rdr_name	`thenRn` \ dfun_name ->
			      returnRn (Just dfun_name)
    )							`thenRn` \ maybe_dfun_name ->

    -- The typechecker checks that all the bindings are for the right class.
    returnRn (InstDecl inst_ty' EmptyMonoBinds [] maybe_dfun_name src_loc)

-- Compare finishSourceTyClDecl
finishSourceInstDecl (InstDecl _       mbinds uprags _               _      )
		     (InstDecl inst_ty _      _      maybe_dfun_name src_loc)
	-- Used for both source decls only
  = ASSERT( not (maybeToBool maybe_dfun_name) )	-- Source decl!
    let
	meth_doc    = text "the bindings in an instance declaration"
	meth_names  = collectLocatedMonoBinders mbinds
	inst_tyvars = case inst_ty of
			HsForAllTy (Just inst_tyvars) _ _ -> inst_tyvars
			other			          -> []
	-- (Slightly strangely) the forall-d tyvars scope over
	-- the method bindings too
    in

	-- Rename the bindings
	-- NB meth_names can be qualified!
    checkDupNames meth_doc meth_names 		`thenRn_`
    extendTyVarEnvFVRn (map hsTyVarName inst_tyvars) (		
	rnMethodBinds [] mbinds
    )						`thenRn` \ (mbinds', meth_fvs) ->
    let 
	binders    = collectMonoBinders mbinds'
	binder_set = mkNameSet binders
    in
	-- Rename the prags and signatures.
	-- Note that the type variables are not in scope here,
	-- so that	instance Eq a => Eq (T a) where
	--			{-# SPECIALISE instance Eq a => Eq (T [a]) #-}
	-- works OK. 
	--
	-- But the (unqualified) method names are in scope
    bindLocalNames binders (
       renameSigsFVs (okInstDclSig binder_set) uprags
    )							`thenRn` \ (uprags', prag_fvs) ->

    returnRn (InstDecl inst_ty mbinds' uprags' maybe_dfun_name src_loc,
	      meth_fvs `plusFV` prag_fvs)
\end{code}

%*********************************************************
%*							*
\subsection{Rules}
%*							*
%*********************************************************

\begin{code}
rnIfaceRuleDecl (IfaceRule rule_name vars fn args rhs src_loc)
  = pushSrcLocRn src_loc	$
    lookupOccRn fn		`thenRn` \ fn' ->
    rnCoreBndrs vars		$ \ vars' ->
    mapRn rnCoreExpr args	`thenRn` \ args' ->
    rnCoreExpr rhs		`thenRn` \ rhs' ->
    returnRn (IfaceRule rule_name vars' fn' args' rhs' src_loc)

rnHsRuleDecl (HsRule rule_name tvs vars lhs rhs src_loc)
  = ASSERT( null tvs )
    pushSrcLocRn src_loc			$

    bindTyVarsFV2Rn doc (map UserTyVar sig_tvs)	$ \ sig_tvs' _ ->
    bindLocalsFVRn doc (map get_var vars)	$ \ ids ->
    mapFvRn rn_var (vars `zip` ids)		`thenRn` \ (vars', fv_vars) ->

    rnExpr lhs					`thenRn` \ (lhs', fv_lhs) ->
    rnExpr rhs					`thenRn` \ (rhs', fv_rhs) ->
    checkRn (validRuleLhs ids lhs')
	    (badRuleLhsErr rule_name lhs')	`thenRn_`
    let
	bad_vars = [var | var <- ids, not (var `elemNameSet` fv_lhs)]
    in
    mapRn (addErrRn . badRuleVar rule_name) bad_vars	`thenRn_`
    returnRn (HsRule rule_name sig_tvs' vars' lhs' rhs' src_loc,
	      fv_vars `plusFV` fv_lhs `plusFV` fv_rhs)
  where
    doc = text "the transformation rule" <+> ptext rule_name
    sig_tvs = extractRuleBndrsTyVars vars
  
    get_var (RuleBndr v)      = v
    get_var (RuleBndrSig v _) = v

    rn_var (RuleBndr v, id)	 = returnRn (RuleBndr id, emptyFVs)
    rn_var (RuleBndrSig v t, id) = rnHsTypeFVs doc t	`thenRn` \ (t', fvs) ->
				   returnRn (RuleBndrSig id t', fvs)
\end{code}


%*********************************************************
%*							*
\subsection{Type, class and iface sig declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its @Name@ representation.
In some cases (type signatures of values),
it is even necessary to go over the type first
in order to get the set of tyvars used by it, make an assoc list,
and then go over it again to rename the tyvars!
However, we can also do some scoping checks at the same time.

\begin{code}
rnTyClDecl (IfaceSig {tcdName = name, tcdType = ty, tcdIdInfo = id_infos, tcdLoc = loc})
  = pushSrcLocRn loc $
    lookupTopBndrRn name		`thenRn` \ name' ->
    rnHsType doc_str ty			`thenRn` \ ty' ->
    mapRn rnIdInfo id_infos		`thenRn` \ id_infos' -> 
    returnRn (IfaceSig {tcdName = name', tcdType = ty', tcdIdInfo = id_infos', tcdLoc = loc})
  where
    doc_str = text "the interface signature for" <+> quotes (ppr name)

rnTyClDecl (TyData {tcdND = new_or_data, tcdCtxt = context, tcdName = tycon,
		    tcdTyVars = tyvars, tcdCons = condecls, tcdNCons = nconstrs,
		    tcdLoc = src_loc, tcdSysNames = sys_names})
  = pushSrcLocRn src_loc $
    lookupTopBndrRn tycon		    	`thenRn` \ tycon' ->
    bindTyVarsRn data_doc tyvars		$ \ tyvars' ->
    rnContext data_doc context 			`thenRn` \ context' ->
    checkDupOrQualNames data_doc con_names	`thenRn_`
    mapRn rnConDecl condecls			`thenRn` \ condecls' ->
    mapRn lookupSysBinder sys_names	        `thenRn` \ sys_names' ->
    returnRn (TyData {tcdND = new_or_data, tcdCtxt = context', tcdName = tycon',
		      tcdTyVars = tyvars', tcdCons = condecls', tcdNCons = nconstrs,
		      tcdDerivs = Nothing, tcdLoc = src_loc, tcdSysNames = sys_names'})
  where
    data_doc = text "the data type declaration for" <+> quotes (ppr tycon)
    con_names = map conDeclName condecls

rnTyClDecl (TySynonym {tcdName = name, tcdTyVars = tyvars, tcdSynRhs = ty, tcdLoc = src_loc})
  = pushSrcLocRn src_loc $
    doptRn Opt_GlasgowExts			`thenRn` \ glaExts ->
    lookupTopBndrRn name			`thenRn` \ name' ->
    bindTyVarsRn syn_doc tyvars 		$ \ tyvars' ->
    rnHsType syn_doc (unquantify glaExts ty)	`thenRn` \ ty' ->
    returnRn (TySynonym {tcdName = name', tcdTyVars = tyvars', tcdSynRhs = ty', tcdLoc = src_loc})
  where
    syn_doc = text "the declaration for type synonym" <+> quotes (ppr name)

	-- For H98 we do *not* universally quantify on the RHS of a synonym
	-- Silently discard context... but the tyvars in the rest won't be in scope
	-- In interface files all types are quantified, so this is a no-op
    unquantify glaExts (HsForAllTy Nothing ctxt ty) | glaExts = ty
    unquantify glaExts ty			     	      = ty

rnTyClDecl (ClassDecl {tcdCtxt = context, tcdName = cname, 
		       tcdTyVars = tyvars, tcdFDs = fds, tcdSigs = sigs, 
		       tcdSysNames = names, tcdLoc = src_loc})
	-- Used for both source and interface file decls
  = pushSrcLocRn src_loc $

    lookupTopBndrRn cname			`thenRn` \ cname' ->

	-- Deal with the implicit tycon and datacon name
	-- They aren't in scope (because they aren't visible to the user)
	-- and what we want to do is simply look them up in the cache;
	-- we jolly well ought to get a 'hit' there!
    mapRn lookupSysBinder names			`thenRn` \ names' ->

	-- Tyvars scope over bindings and context
    bindTyVars2Rn cls_doc tyvars		$ \ clas_tyvar_names tyvars' ->

	-- Check the superclasses
    rnContext cls_doc context			`thenRn` \ context' ->

	-- Check the functional dependencies
    rnFds cls_doc fds				`thenRn` \ fds' ->

	-- Check the signatures
	-- First process the class op sigs (op_sigs), then the fixity sigs (non_op_sigs).
    let
	(op_sigs, non_op_sigs) = partition isClassOpSig sigs
	sig_rdr_names_w_locs   = [(op,locn) | ClassOpSig op _ _ locn <- sigs]
    in
    checkDupOrQualNames sig_doc sig_rdr_names_w_locs		`thenRn_` 
    mapRn (rnClassOp cname' clas_tyvar_names fds') op_sigs	`thenRn` \ sigs' ->
    let
	binders = mkNameSet [ nm | (ClassOpSig nm _ _ _) <- sigs' ]
    in
    renameSigs (okClsDclSig binders) non_op_sigs	  `thenRn` \ non_ops' ->

	-- Typechecker is responsible for checking that we only
	-- give default-method bindings for things in this class.
	-- The renamer *could* check this for class decls, but can't
	-- for instance decls.

    returnRn (ClassDecl { tcdCtxt = context', tcdName = cname', tcdTyVars = tyvars',
			  tcdFDs = fds', tcdSigs = non_ops' ++ sigs', tcdMeths = Nothing, 
			  tcdSysNames = names', tcdLoc = src_loc})
  where
    cls_doc  = text "the declaration for class" 	<+> ppr cname
    sig_doc  = text "the signatures for class"  	<+> ppr cname

rnClassOp clas clas_tyvars clas_fds sig@(ClassOpSig op dm_stuff ty locn)
  = pushSrcLocRn locn $
    lookupTopBndrRn op			`thenRn` \ op_name ->
    
    	-- Check the signature
    rnHsSigType (quotes (ppr op)) ty	`thenRn` \ new_ty ->
    
    	-- Make the default-method name
    (case dm_stuff of 
        DefMeth dm_rdr_name
    	    -> 	-- Imported class that has a default method decl
    		-- See comments with tname, snames, above
    	    	lookupSysBinder dm_rdr_name 	`thenRn` \ dm_name ->
		returnRn (DefMeth dm_name)
	    		-- An imported class decl for a class decl that had an explicit default
	    		-- method, mentions, rather than defines,
	    		-- the default method, so we must arrange to pull it in

        GenDefMeth -> returnRn GenDefMeth
        NoDefMeth  -> returnRn NoDefMeth
    )						`thenRn` \ dm_stuff' ->
    
    returnRn (ClassOpSig op_name dm_stuff' new_ty locn)

finishSourceTyClDecl :: RdrNameTyClDecl -> RenamedTyClDecl -> RnMS (RenamedTyClDecl, FreeVars)
	-- Used for source file decls only
	-- Renames the default-bindings of a class decl
	--	   the derivings of a data decl
finishSourceTyClDecl (TyData {tcdDerivs = Just derivs, tcdLoc = src_loc})	-- Derivings in here
		     rn_ty_decl							-- Everything else is here
  = pushSrcLocRn src_loc	 $
    mapRn rnDeriv derivs	`thenRn` \ derivs' ->
    returnRn (rn_ty_decl {tcdDerivs = Just derivs'}, mkNameSet derivs')

finishSourceTyClDecl (ClassDecl {tcdMeths = Just mbinds, tcdLoc = src_loc})	-- Get mbinds from here
	 rn_cls_decl@(ClassDecl {tcdTyVars = tyvars})				-- Everything else is here
  -- There are some default-method bindings (abeit possibly empty) so 
  -- this is a source-code class declaration
  = 	-- The newLocals call is tiresome: given a generic class decl
	--	class C a where
	--	  op :: a -> a
	--	  op {| x+y |} (Inl a) = ...
	--	  op {| x+y |} (Inr b) = ...
	--	  op {| a*b |} (a*b)   = ...
	-- we want to name both "x" tyvars with the same unique, so that they are
	-- easy to group together in the typechecker.  
	-- Hence the 
    pushSrcLocRn src_loc				$
    extendTyVarEnvFVRn (map hsTyVarName tyvars)		$
    getLocalNameEnv					`thenRn` \ name_env ->
    let
	meth_rdr_names_w_locs = collectLocatedMonoBinders mbinds
	gen_rdr_tyvars_w_locs = [(tv,src_loc) | tv <- extractGenericPatTyVars mbinds,
						not (tv `elemRdrEnv` name_env)]
    in
    checkDupOrQualNames meth_doc meth_rdr_names_w_locs	`thenRn_`
    newLocalsRn gen_rdr_tyvars_w_locs			`thenRn` \ gen_tyvars ->
    rnMethodBinds gen_tyvars mbinds			`thenRn` \ (mbinds', meth_fvs) ->
    returnRn (rn_cls_decl {tcdMeths = Just mbinds'}, meth_fvs)
  where
    meth_doc = text "the default-methods for class"	<+> ppr (tcdName rn_cls_decl)

finishSourceTyClDecl _ tycl_decl = returnRn (tycl_decl, emptyFVs)
	-- Not a class declaration
\end{code}


%*********************************************************
%*							*
\subsection{Support code for type/data declarations}
%*							*
%*********************************************************

\begin{code}
rnDeriv :: RdrName -> RnMS Name
rnDeriv cls
  = lookupOccRn cls	`thenRn` \ clas_name ->
    checkRn (getUnique clas_name `elem` derivableClassKeys)
	    (derivingNonStdClassErr clas_name)	`thenRn_`
    returnRn clas_name
\end{code}

\begin{code}
conDeclName :: RdrNameConDecl -> (RdrName, SrcLoc)
conDeclName (ConDecl n _ _ _ _ l) = (n,l)

rnConDecl :: RdrNameConDecl -> RnMS RenamedConDecl
rnConDecl (ConDecl name wkr tvs cxt details locn)
  = pushSrcLocRn locn $
    checkConName name		`thenRn_` 
    lookupTopBndrRn name	`thenRn` \ new_name ->

    lookupSysBinder wkr		`thenRn` \ new_wkr ->
	-- See comments with ClassDecl

    bindTyVarsRn doc tvs 		$ \ new_tyvars ->
    rnContext doc cxt			`thenRn` \ new_context ->
    rnConDetails doc locn details	`thenRn` \ new_details -> 
    returnRn (ConDecl new_name new_wkr new_tyvars new_context new_details locn)
  where
    doc = text "the definition of data constructor" <+> quotes (ppr name)

rnConDetails doc locn (VanillaCon tys)
  = mapRn (rnBangTy doc) tys	`thenRn` \ new_tys  ->
    returnRn (VanillaCon new_tys)

rnConDetails doc locn (InfixCon ty1 ty2)
  = rnBangTy doc ty1  		`thenRn` \ new_ty1 ->
    rnBangTy doc ty2  		`thenRn` \ new_ty2 ->
    returnRn (InfixCon new_ty1 new_ty2)

rnConDetails doc locn (RecCon fields)
  = checkDupOrQualNames doc field_names	`thenRn_`
    mapRn (rnField doc) fields		`thenRn` \ new_fields ->
    returnRn (RecCon new_fields)
  where
    field_names = [(fld, locn) | (flds, _) <- fields, fld <- flds]

rnField doc (names, ty)
  = mapRn lookupTopBndrRn names	`thenRn` \ new_names ->
    rnBangTy doc ty		`thenRn` \ new_ty ->
    returnRn (new_names, new_ty) 

rnBangTy doc (Banged ty)
  = rnHsType doc ty		`thenRn` \ new_ty ->
    returnRn (Banged new_ty)

rnBangTy doc (Unbanged ty)
  = rnHsType doc ty 		`thenRn` \ new_ty ->
    returnRn (Unbanged new_ty)

rnBangTy doc (Unpacked ty)
  = rnHsType doc ty 		`thenRn` \ new_ty ->
    returnRn (Unpacked new_ty)

-- This data decl will parse OK
--	data T = a Int
-- treating "a" as the constructor.
-- It is really hard to make the parser spot this malformation.
-- So the renamer has to check that the constructor is legal
--
-- We can get an operator as the constructor, even in the prefix form:
--	data T = :% Int Int
-- from interface files, which always print in prefix form

checkConName name
  = checkRn (isRdrDataCon name)
	    (badDataCon name)
\end{code}


%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnHsTypeFVs :: SDoc -> RdrNameHsType -> RnMS (RenamedHsType, FreeVars)
rnHsTypeFVs doc_str ty 
  = rnHsType doc_str ty		`thenRn` \ ty' ->
    returnRn (ty', extractHsTyNames ty')

rnHsSigTypeFVs :: SDoc -> RdrNameHsType -> RnMS (RenamedHsType, FreeVars)
rnHsSigTypeFVs doc_str ty
  = rnHsSigType doc_str ty	`thenRn` \ ty' ->
    returnRn (ty', extractHsTyNames ty')

rnHsSigType :: SDoc -> RdrNameHsType -> RnMS RenamedHsType
	-- rnHsSigType is used for source-language type signatures,
	-- which use *implicit* universal quantification.
rnHsSigType doc_str ty
  = rnHsType (text "the type signature for" <+> doc_str) ty
    
---------------------------------------
rnHsType :: SDoc -> RdrNameHsType -> RnMS RenamedHsType

rnHsType doc (HsForAllTy Nothing ctxt ty)
	-- Implicit quantifiction in source code (no kinds on tyvars)
	-- Given the signature  C => T  we universally quantify 
	-- over FV(T) \ {in-scope-tyvars} 
  = getLocalNameEnv		`thenRn` \ name_env ->
    let
	mentioned_in_tau  = extractHsTyRdrTyVars ty
	mentioned_in_ctxt = extractHsCtxtRdrTyVars ctxt
	mentioned	  = nub (mentioned_in_tau ++ mentioned_in_ctxt)
	forall_tyvars	  = filter (not . (`elemRdrEnv` name_env)) mentioned
    in
    rnForAll doc (map UserTyVar forall_tyvars) ctxt ty

rnHsType doc (HsForAllTy (Just forall_tyvars) ctxt tau)
	-- Explicit quantification.
	-- Check that the forall'd tyvars are actually 
	-- mentioned in the type, and produce a warning if not
  = let
	mentioned_in_tau		= extractHsTyRdrTyVars tau
	mentioned_in_ctxt		= extractHsCtxtRdrTyVars ctxt
	mentioned			= nub (mentioned_in_tau ++ mentioned_in_ctxt)
	forall_tyvar_names		= hsTyVarNames forall_tyvars

	-- Explicitly quantified but not mentioned in ctxt or tau
	warn_guys			= filter (`notElem` mentioned) forall_tyvar_names
    in
    mapRn_ (forAllWarn doc tau) warn_guys	`thenRn_`
    rnForAll doc forall_tyvars ctxt tau

rnHsType doc (HsTyVar tyvar)
  = lookupOccRn tyvar 		`thenRn` \ tyvar' ->
    returnRn (HsTyVar tyvar')

rnHsType doc (HsOpTy ty1 opname ty2)
  = lookupOccRn opname	`thenRn` \ name' ->
    rnHsType doc ty1	`thenRn` \ ty1' ->
    rnHsType doc ty2	`thenRn` \ ty2' -> 
    returnRn (HsOpTy ty1' name' ty2')

rnHsType doc (HsNumTy i)
  | i == 1    = returnRn (HsNumTy i)
  | otherwise = failWithRn (HsNumTy i)
			   (ptext SLIT("Only unit numeric type pattern is valid"))

rnHsType doc (HsFunTy ty1 ty2)
  = rnHsType doc ty1	`thenRn` \ ty1' ->
	-- Might find a for-all as the arg of a function type
    rnHsType doc ty2	`thenRn` \ ty2' ->
	-- Or as the result.  This happens when reading Prelude.hi
	-- when we find return :: forall m. Monad m -> forall a. a -> m a
    returnRn (HsFunTy ty1' ty2')

rnHsType doc (HsListTy ty)
  = rnHsType doc ty				`thenRn` \ ty' ->
    returnRn (HsListTy ty')

-- Unboxed tuples are allowed to have poly-typed arguments.  These
-- sometimes crop up as a result of CPR worker-wrappering dictionaries.
rnHsType doc (HsTupleTy (HsTupCon _ boxity arity) tys)
	-- Don't do lookupOccRn, because this is built-in syntax
	-- so it doesn't need to be in scope
  = mapRn (rnHsType doc) tys	  	`thenRn` \ tys' ->
    returnRn (HsTupleTy (HsTupCon tup_name boxity arity) tys')
  where
    tup_name = tupleTyCon_name boxity arity
  

rnHsType doc (HsAppTy ty1 ty2)
  = rnHsType doc ty1		`thenRn` \ ty1' ->
    rnHsType doc ty2		`thenRn` \ ty2' ->
    returnRn (HsAppTy ty1' ty2')

rnHsType doc (HsPredTy pred)
  = rnPred doc pred	`thenRn` \ pred' ->
    returnRn (HsPredTy pred')

rnHsTypes doc tys = mapRn (rnHsType doc) tys
\end{code}

\begin{code}
rnForAll doc forall_tyvars ctxt ty
  = bindTyVarsRn doc forall_tyvars	$ \ new_tyvars ->
    rnContext doc ctxt			`thenRn` \ new_ctxt ->
    rnHsType doc ty			`thenRn` \ new_ty ->
    returnRn (mkHsForAllTy (Just new_tyvars) new_ctxt new_ty)
\end{code}

\begin{code}
rnContext :: SDoc -> RdrNameContext -> RnMS RenamedContext
rnContext doc ctxt
  = mapRn rn_pred ctxt		`thenRn` \ theta ->
    let
	(_, dups) = removeDupsEq theta
		-- We only have equality, not ordering
    in
	-- Check for duplicate assertions
	-- If this isn't an error, then it ought to be:
    mapRn (addWarnRn . dupClassAssertWarn theta) dups		`thenRn_`
    returnRn theta
  where
   	--Someone discovered that @CCallable@ and @CReturnable@
	-- could be used in contexts such as:
	--	foo :: CCallable a => a -> PrimIO Int
	-- Doing this utterly wrecks the whole point of introducing these
	-- classes so we specifically check that this isn't being done.
    rn_pred pred = rnPred doc pred				`thenRn` \ pred'->
		   checkRn (not (bad_pred pred'))
			   (naughtyCCallContextErr pred')	`thenRn_`
		   returnRn pred'

    bad_pred (HsClassP clas _) = getUnique clas `elem` cCallishClassKeys
    bad_pred other	       = False


rnPred doc (HsClassP clas tys)
  = lookupOccRn clas		`thenRn` \ clas_name ->
    rnHsTypes doc tys		`thenRn` \ tys' ->
    returnRn (HsClassP clas_name tys')

rnPred doc (HsIParam n ty)
  = newIPName n			`thenRn` \ name ->
    rnHsType doc ty		`thenRn` \ ty' ->
    returnRn (HsIParam name ty')
\end{code}

\begin{code}
rnFds :: SDoc -> [FunDep RdrName] -> RnMS [FunDep Name]

rnFds doc fds
  = mapRn rn_fds fds
  where
    rn_fds (tys1, tys2)
      =	rnHsTyVars doc tys1		`thenRn` \ tys1' ->
	rnHsTyVars doc tys2		`thenRn` \ tys2' ->
	returnRn (tys1', tys2')

rnHsTyVars doc tvs  = mapRn (rnHsTyvar doc) tvs
rnHsTyvar doc tyvar = lookupOccRn tyvar
\end{code}

%*********************************************************
%*							 *
\subsection{IdInfo}
%*							 *
%*********************************************************

\begin{code}
rnIdInfo (HsWorker worker arity)
  = lookupOccRn worker			`thenRn` \ worker' ->
    returnRn (HsWorker worker' arity)

rnIdInfo (HsUnfold inline expr)	= rnCoreExpr expr `thenRn` \ expr' ->
				  returnRn (HsUnfold inline expr')
rnIdInfo (HsStrictness str)     = returnRn (HsStrictness str)
rnIdInfo (HsArity arity)	= returnRn (HsArity arity)
rnIdInfo HsNoCafRefs		= returnRn HsNoCafRefs
rnIdInfo HsCprInfo		= returnRn HsCprInfo
\end{code}

@UfCore@ expressions.

\begin{code}
rnCoreExpr (UfType ty)
  = rnHsType (text "unfolding type") ty	`thenRn` \ ty' ->
    returnRn (UfType ty')

rnCoreExpr (UfVar v)
  = lookupOccRn v 	`thenRn` \ v' ->
    returnRn (UfVar v')

rnCoreExpr (UfLit l)
  = returnRn (UfLit l)

rnCoreExpr (UfLitLit l ty)
  = rnHsType (text "litlit") ty	`thenRn` \ ty' ->
    returnRn (UfLitLit l ty')

rnCoreExpr (UfCCall cc ty)
  = rnHsType (text "ccall") ty	`thenRn` \ ty' ->
    returnRn (UfCCall cc ty')

rnCoreExpr (UfTuple (HsTupCon _ boxity arity) args) 
  = mapRn rnCoreExpr args		`thenRn` \ args' ->
    returnRn (UfTuple (HsTupCon tup_name boxity arity) args')
  where
    tup_name = getName (dataConId (tupleCon boxity arity))
	-- Get the *worker* name and use that

rnCoreExpr (UfApp fun arg)
  = rnCoreExpr fun		`thenRn` \ fun' ->
    rnCoreExpr arg		`thenRn` \ arg' ->
    returnRn (UfApp fun' arg')

rnCoreExpr (UfCase scrut bndr alts)
  = rnCoreExpr scrut			`thenRn` \ scrut' ->
    bindCoreLocalRn bndr		$ \ bndr' ->
    mapRn rnCoreAlt alts		`thenRn` \ alts' ->
    returnRn (UfCase scrut' bndr' alts')

rnCoreExpr (UfNote note expr) 
  = rnNote note			`thenRn` \ note' ->
    rnCoreExpr expr		`thenRn` \ expr' ->
    returnRn  (UfNote note' expr')

rnCoreExpr (UfLam bndr body)
  = rnCoreBndr bndr 		$ \ bndr' ->
    rnCoreExpr body		`thenRn` \ body' ->
    returnRn (UfLam bndr' body')

rnCoreExpr (UfLet (UfNonRec bndr rhs) body)
  = rnCoreExpr rhs		`thenRn` \ rhs' ->
    rnCoreBndr bndr 		$ \ bndr' ->
    rnCoreExpr body		`thenRn` \ body' ->
    returnRn (UfLet (UfNonRec bndr' rhs') body')

rnCoreExpr (UfLet (UfRec pairs) body)
  = rnCoreBndrs bndrs		$ \ bndrs' ->
    mapRn rnCoreExpr rhss	`thenRn` \ rhss' ->
    rnCoreExpr body		`thenRn` \ body' ->
    returnRn (UfLet (UfRec (bndrs' `zip` rhss')) body')
  where
    (bndrs, rhss) = unzip pairs
\end{code}

\begin{code}
rnCoreBndr (UfValBinder name ty) thing_inside
  = rnHsType doc ty		`thenRn` \ ty' ->
    bindCoreLocalRn name	$ \ name' ->
    thing_inside (UfValBinder name' ty')
  where
    doc = text "unfolding id"
    
rnCoreBndr (UfTyBinder name kind) thing_inside
  = bindCoreLocalRn name		$ \ name' ->
    thing_inside (UfTyBinder name' kind)
    
rnCoreBndrs []     thing_inside = thing_inside []
rnCoreBndrs (b:bs) thing_inside = rnCoreBndr b		$ \ name' ->
				  rnCoreBndrs bs 	$ \ names' ->
				  thing_inside (name':names')
\end{code}    

\begin{code}
rnCoreAlt (con, bndrs, rhs)
  = rnUfCon con 			`thenRn` \ con' ->
    bindCoreLocalsRn bndrs		$ \ bndrs' ->
    rnCoreExpr rhs			`thenRn` \ rhs' ->
    returnRn (con', bndrs', rhs')

rnNote (UfCoerce ty)
  = rnHsType (text "unfolding coerce") ty	`thenRn` \ ty' ->
    returnRn (UfCoerce ty')

rnNote (UfSCC cc)   = returnRn (UfSCC cc)
rnNote UfInlineCall = returnRn UfInlineCall
rnNote UfInlineMe   = returnRn UfInlineMe


rnUfCon UfDefault
  = returnRn UfDefault

rnUfCon (UfTupleAlt (HsTupCon _ boxity arity))
  = returnRn (UfTupleAlt (HsTupCon tup_name boxity arity))
  where
    tup_name = getName (tupleCon boxity arity)

rnUfCon (UfDataAlt con)
  = lookupOccRn con		`thenRn` \ con' ->
    returnRn (UfDataAlt con')

rnUfCon (UfLitAlt lit)
  = returnRn (UfLitAlt lit)

rnUfCon (UfLitLitAlt lit ty)
  = rnHsType (text "litlit") ty		`thenRn` \ ty' ->
    returnRn (UfLitLitAlt lit ty')
\end{code}

%*********************************************************
%*							 *
\subsection{Rule shapes}
%*							 *
%*********************************************************

Check the shape of a transformation rule LHS.  Currently
we only allow LHSs of the form @(f e1 .. en)@, where @f@ is
not one of the @forall@'d variables.

\begin{code}
validRuleLhs foralls lhs
  = check lhs
  where
    check (HsApp e1 e2) 		  = check e1
    check (HsVar v) | v `notElem` foralls = True
    check other				  = False
\end{code}


%*********************************************************
%*							 *
\subsection{Errors}
%*							 *
%*********************************************************

\begin{code}
derivingNonStdClassErr clas
  = hsep [ptext SLIT("non-standard class"), ppr clas, ptext SLIT("in deriving clause")]

badDataCon name
   = hsep [ptext SLIT("Illegal data constructor name"), quotes (ppr name)]

forAllWarn doc ty tyvar
  = doptRn Opt_WarnUnusedMatches `thenRn` \ warn_unused -> case () of
    () | not warn_unused -> returnRn ()
       | otherwise
       -> getModeRn		`thenRn` \ mode ->
          case mode of {
#ifndef DEBUG
	     InterfaceMode -> returnRn () ; -- Don't warn of unused tyvars in interface files
		                            -- unless DEBUG is on, in which case it is slightly
					    -- informative.  They can arise from mkRhsTyLam,
#endif					    -- leading to (say) 	f :: forall a b. [b] -> [b]
	     other ->
		addWarnRn (
		   sep [ptext SLIT("The universally quantified type variable") <+> quotes (ppr tyvar),
		   nest 4 (ptext SLIT("does not appear in the type") <+> quotes (ppr ty))]
		   $$
		   (ptext SLIT("In") <+> doc)
                )
          }

badRuleLhsErr name lhs
  = sep [ptext SLIT("Rule") <+> ptext name <> colon,
	 nest 4 (ptext SLIT("Illegal left-hand side:") <+> ppr lhs)]
    $$
    ptext SLIT("LHS must be of form (f e1 .. en) where f is not forall'd")

badRuleVar name var
  = sep [ptext SLIT("Rule") <+> ptext name <> colon,
	 ptext SLIT("Forall'd variable") <+> quotes (ppr var) <+> 
		ptext SLIT("does not appear on left hand side")]

badExtName :: ExtName -> Message
badExtName ext_nm
  = sep [quotes (ppr ext_nm) <+> ptext SLIT("is not a valid C identifier")]

dupClassAssertWarn ctxt (assertion : dups)
  = sep [hsep [ptext SLIT("Duplicate class assertion"), 
	       quotes (ppr assertion),
	       ptext SLIT("in the context:")],
	 nest 4 (pprHsContext ctxt <+> ptext SLIT("..."))]

naughtyCCallContextErr (HsClassP clas _)
  = sep [ptext SLIT("Can't use class") <+> quotes (ppr clas), 
	 ptext SLIT("in a context")]
\end{code}
