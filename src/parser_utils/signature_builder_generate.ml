(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast_utils = Flow_ast_utils

module Ast = Flow_ast

module LocMap = Utils_js.LocMap

module Kind = Signature_builder_kind
module Entry = Signature_builder_entry

module Deps = Signature_builder_deps.With_Loc
module File_sig = File_sig.With_Loc
module Error = Deps.Error
module Dep = Deps.Dep

(* The generator creates new AST nodes, some of whose locations do not map back very accurately to
   original locations. While these are relatively unimportant, in that they should never make their
   way into type errors, making them Loc.none is risky because they would make Flow crash in the
   event of unforeseen bugs. Instead we reuse some nearby locations as approximations. *)
let approx_loc loc = loc

module T = struct
  type type_ = (Loc.t, Loc.t) Ast.Type.t

  and decl =
    (* type definitions *)
    | Type of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        right: type_;
      }
    | OpaqueType of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        supertype: type_ option;
      }
    | Interface of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic list;
        body: Loc.t * object_type;
      }
    (* declarations and outlined expressions *)
    | ClassDecl of class_t
    | FunctionDecl of little_annotation
    | VariableDecl of little_annotation
    (* remote *)
    | ImportNamed of {
        kind: Ast.Statement.ImportDeclaration.importKind;
        source: Loc.t Ast_utils.source;
        name: Loc.t Ast_utils.ident;
      }
    | ImportStar of {
        kind: Ast.Statement.ImportDeclaration.importKind;
        source: Loc.t Ast_utils.source;
      }
    | Require of {
        source: Loc.t Ast_utils.source;
        name: Loc.t Ast_utils.ident Nel.t option;
      }

  and generic = Loc.t * (Loc.t, Loc.t) Ast.Type.Generic.t

  and class_implement = (Loc.t, Loc.t) Ast.Class.Implements.t

  and little_annotation =
    | TYPE of type_
    | EXPR of (Loc.t * expr_type)

  and expr_type =
    (* types and expressions *)
    | Function of function_t

    | ObjectLiteral of {
        frozen: bool;
        properties: (Loc.t * object_property_t) Nel.t
      }
    | ArrayLiteral of array_element_t Nel.t

    | ValueRef of reference (* typeof `x` *)

    | NumberLiteral of Ast.NumberLiteral.t
    | StringLiteral of Ast.StringLiteral.t
    | BooleanLiteral of bool
    | Number
    | String
    | Boolean

    | Void
    | Null

    | TypeCast of type_

    | Outline of outlinable_t

    | ObjectDestruct of (Loc.t * expr_type) * (Loc.t * string)

    | FixMe

  and object_type = (Loc.t, Loc.t) Ast.Type.Object.t

  and object_key = (Loc.t, Loc.t) Ast.Expression.Object.Property.key

  and outlinable_t =
    | Class of (Loc.t * string) option * class_t
    | DynamicImport of Loc.t * Ast.StringLiteral.t
    | DynamicRequire of (Loc.t, Loc.t) Ast.Expression.t

  and function_t =
    | FUNCTION of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        params: function_params;
        return: little_annotation;
      }

  and function_params =
    Loc.t * pattern list * (Loc.t * pattern) option

  and pattern =
      Loc.t * Loc.t Ast.Identifier.t option * bool (* optional *) * type_

  and class_t =
    | CLASS of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic option;
        implements: class_implement list;
        body: Loc.t * (Loc.t * class_element_t) list;
      }
    | DECLARE_CLASS of {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        extends: generic option;
        mixins: generic list;
        implements: class_implement list;
        body: Loc.t * object_type;
      }

  and class_element_t =
    | CMethod of object_key * Ast.Class.Method.kind * bool (* static *) * (Loc.t * function_t)
    | CProperty of object_key * bool (* static *) * Loc.t Ast.Variance.t option * type_
    | CPrivateField of string * bool (* static *) * Loc.t Ast.Variance.t option * type_

  and object_property_t =
    | OInit of object_key * (Loc.t * expr_type)
    | OMethod of object_key * (Loc.t * function_t)
    | OGet of object_key * (Loc.t * function_t)
    | OSet of object_key * (Loc.t * function_t)

  and array_element_t =
    | AInit of (Loc.t * expr_type)

  and reference =
    | RLexical of Loc.t * string
    | RPath of Loc.t * reference * (Loc.t * string)

  module FixMe = struct

    let mk_type loc =
      loc, Ast.Type.Any

    let mk_little_annotation loc =
      TYPE (mk_type loc)

    let mk_pattern default loc =
      if default
      then loc, Some (loc, "_"), true, mk_type loc
      else loc, None, false, mk_type loc

    let mk_expr_type loc =
      loc, FixMe

    let mk_extends _loc =
      None

    let mk_decl loc =
      VariableDecl (mk_little_annotation loc)

  end

  let rec summarize_array loc = function
    | AInit (_, et), aes ->
      List.fold_left (fun acc -> function
        | AInit (_, et) -> data_optional_pair loc acc (Some et)
      ) (Some et) aes

  and data_optional_pair loc data1 data2 = match data1, data2 with
    | Some et1, Some et2 -> summarize_expr_type_pair loc et1 et2
    | None, _ | _, None -> None

  and summarize_expr_type_pair loc expr_type1 expr_type2 = match expr_type1, expr_type2 with
    | ArrayLiteral array1, ArrayLiteral array2 ->
      let array' = summarize_array_pair loc array1 array2 in
      begin match array' with
        | None -> None
        | Some et -> Some (ArrayLiteral (AInit (loc, et), []))
      end
    | ObjectLiteral { frozen = frozen1; properties = object1 },
        ObjectLiteral { frozen = frozen2; properties = object2 } ->
      let frozen' = match frozen1, frozen2 with
        | true, true -> Some true
        | false, false -> Some false
        | _ -> None in
      let object' = summarize_object_pair loc object1 object2 in
      begin match frozen', object' with
        | Some frozen, Some xets ->
          Some (ObjectLiteral { frozen; properties = Nel.rev_map (fun (x, et) ->
            loc, OInit (x, (loc, et))
          ) xets })
        | _ -> None
      end
    | (NumberLiteral _ | Number), (NumberLiteral _ | Number) -> Some Number
    | (StringLiteral _ | String), (StringLiteral _ | String) -> Some String
    | (BooleanLiteral _ | Boolean), (BooleanLiteral _ | Boolean) -> Some Boolean
    | Null, Null -> Some Null

    | _ -> None

  and summarize_array_pair loc array1 array2 =
    data_optional_pair loc (summarize_array loc array1) (summarize_array loc array2)

  and summarize_object_pair =
    let abs_object_key object_key =
      let open Ast.Expression.Object.Property in
      match object_key with
        | Literal (_, x) -> `Literal x
        | Identifier (_, x) -> `Identifier x
        | PrivateName (_, (_, x)) -> `PrivateName x
        | _ -> assert false in
    let object_key loc abs_object_key =
      let open Ast.Expression.Object.Property in
      match abs_object_key with
        | `Literal x -> Literal (loc, x)
        | `Identifier x -> Identifier (loc, x)
        | `PrivateName x -> PrivateName (loc, (loc, x)) in
    let compare_object_property =
      let abs_object_key = function
        | _, OInit (object_key, _)
        | _, OMethod (object_key, _)
        | _, OGet (object_key, _)
        | _, OSet (object_key, _)
          -> abs_object_key object_key
      in
      fun op1 op2 ->
        Pervasives.compare (abs_object_key op1) (abs_object_key op2) in
    let summarize_object_property_pair loc op1 op2 = match snd op1, snd op2 with
      | OInit (object_key1, (_, et1)), OInit (object_key2, (_, et2)) ->
        let x = abs_object_key object_key1 in
        if x = abs_object_key object_key2
        then match summarize_expr_type_pair loc et1 et2 with
          | Some et -> Some (object_key loc x, et)
          | None -> None
        else None
      | _ -> None in
    let rec summarize_object_pair loc acc = function
      | [], [] -> acc
      | [], _ | _, [] -> None
      | op1::ops1, op2::ops2 ->
        let acc = match summarize_object_property_pair loc op1 op2, acc with
          | None, _ | _, None -> None
          | Some xet, Some xets -> Some (Nel.cons xet xets) in
        summarize_object_pair loc acc (ops1, ops2)
    in
    fun loc object1 object2 ->
      let op1, ops1 = Nel.of_list_exn @@ List.sort compare_object_property @@ Nel.to_list object1 in
      let op2, ops2 = Nel.of_list_exn @@ List.sort compare_object_property @@ Nel.to_list object2 in
      let init = match summarize_object_property_pair loc op1 op2 with
        | None -> None
        | Some xet -> Some (xet, []) in
      summarize_object_pair loc init (ops1, ops2)

  module Outlined: sig
    type 'a t
    val create: unit -> 'a t
    val next: 'a t -> Loc.t -> (Loc.t Ast.Identifier.t -> Loc.t Ast.Identifier.t option * 'a)
      -> Loc.t Ast.Identifier.t
    val get: 'a t -> 'a list
  end = struct
    type 'a t = (int * 'a list) ref
    let create () = ref (0, [])
    let next outlined outlined_loc f =
      let n, l = !outlined in
      let n = n + 1 in
      let id = outlined_loc, Printf.sprintf "$%d" n in
      let id_opt, x = f id in
      let n, id = match id_opt with
        | None -> n, id
        | Some id -> n - 1, id in
      let l = x :: l in
      outlined := (n, l);
      id
    let get outlined =
      let _, l = !outlined in
      l
  end

  let param_of_type (loc, name, optional, annot) =
    loc, {
      Ast.Type.Function.Param.name;
      annot;
      optional;
    }

  let type_of_generic (loc, gt) =
    loc, Ast.Type.Generic gt

  let source_of_source (loc, x) =
    loc, { Ast.StringLiteral.value = x; raw = x; }

  let rec type_of_expr_type outlined = function
    | loc, Function function_t -> type_of_function outlined (loc, function_t)
    | loc, ObjectLiteral { frozen = true; properties = (pt, pts) } ->
      let ot = loc, Ast.Type.Object {
        Ast.Type.Object.exact = true;
        inexact = false;
        properties = List.map (type_of_object_property outlined) (pt :: pts)
      } in
      loc, Ast.Type.Generic {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified (loc, "$TEMPORARY$Object$freeze");
        targs = Some (loc, [ot])
      }
    | loc, ObjectLiteral { frozen = false; properties = (pt, pts) } ->
      loc, Ast.Type.Object {
        Ast.Type.Object.exact = true;
        inexact = false;
        properties = Core_list.map ~f:(type_of_object_property outlined) (pt :: pts)
      }
    | loc, ArrayLiteral ets ->
      loc, Ast.Type.Array (match ets with
        | et, [] -> type_of_array_element outlined et
        | et1, et2::ets ->
          loc, Ast.Type.Union (
            type_of_array_element outlined et1,
            type_of_array_element outlined et2,
            Core_list.map ~f:(type_of_array_element outlined) ets
          )
      )

    | loc, ValueRef reference ->
      loc, Ast.Type.Typeof (type_of_generic (loc, {
        Ast.Type.Generic.id = generic_id_of_reference reference;
        targs = None;
      }))
    | loc, NumberLiteral nt -> loc, Ast.Type.Generic {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified (loc, "$TEMPORARY$number");
        targs = Some (loc, [loc, Ast.Type.NumberLiteral nt])
      }
    | loc, StringLiteral st -> loc, Ast.Type.Generic {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified (loc, "$TEMPORARY$string");
        targs = Some (loc, [loc, Ast.Type.StringLiteral st])
      }
    | loc, BooleanLiteral b -> loc, Ast.Type.Generic {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified (loc, "$TEMPORARY$boolean");
        targs = Some (loc, [loc, Ast.Type.BooleanLiteral b])
      }
    | loc, Number -> loc, Ast.Type.Number
    | loc, String -> loc, Ast.Type.String
    | loc, Boolean -> loc, Ast.Type.Boolean
    | loc, Void -> loc, Ast.Type.Void
    | loc, Null -> loc, Ast.Type.Null

    | _loc, TypeCast t -> t

    | loc, Outline ht ->
      let f = outlining_fun outlined loc ht in
      let id = Outlined.next outlined loc f in
      loc, Ast.Type.Typeof (type_of_generic (loc, {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Unqualified id;
        targs = None;
      }))

    | loc, ObjectDestruct (expr_type, prop) ->
      let t = type_of_expr_type outlined expr_type in
      let f id = None, (fst expr_type, Ast.Statement.DeclareVariable {
        Ast.Statement.DeclareVariable.id;
        annot = Ast.Type.Available (fst t, t);
      }) in
      let id = Outlined.next outlined loc f in
      loc, Ast.Type.Typeof (type_of_generic (loc, {
        Ast.Type.Generic.id = Ast.Type.Generic.Identifier.Qualified (loc, {
          Ast.Type.Generic.Identifier.qualification = Ast.Type.Generic.Identifier.Unqualified id;
          id = prop
        });
        targs = None;
      }));

    | loc, FixMe ->
      FixMe.mk_type loc

  and generic_id_of_reference = function
    | RLexical (loc, x) -> Ast.Type.Generic.Identifier.Unqualified (loc, x)
    | RPath (path_loc, reference, (loc, x)) -> Ast.Type.Generic.Identifier.Qualified (path_loc, {
        Ast.Type.Generic.Identifier.qualification = generic_id_of_reference reference;
        id = loc, x
      })

  and outlining_fun outlined decl_loc ht id = match ht with
    | Class (id_opt, class_t) -> id_opt,
      let id = match id_opt with
        | None -> id
        | Some id -> id in
      stmt_of_decl outlined decl_loc id (ClassDecl class_t)
    | DynamicImport (source_loc, source_lit) -> None,
      let importKind = Ast.Statement.ImportDeclaration.ImportValue in
      let source = source_loc, source_lit in
      let default = None in
      let specifiers =
        Some (Ast.Statement.ImportDeclaration.ImportNamespaceSpecifier (decl_loc, id)) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
        specifiers;
      }
    | DynamicRequire require -> None,
      let kind = Ast.Statement.VariableDeclaration.Const in
      let pattern = decl_loc, Ast.Pattern.Identifier {
        Ast.Pattern.Identifier.name = id;
        annot = Ast.Type.Missing (fst id);
        optional = false;
      } in
      let declaration = {
        Ast.Statement.VariableDeclaration.Declarator.id = pattern;
        init = Some require;
      } in
      decl_loc, Ast.Statement.VariableDeclaration {
        Ast.Statement.VariableDeclaration.kind;
        declarations = [decl_loc, declaration];
      }

  and type_of_array_element outlined = function
    | AInit expr_type -> type_of_expr_type outlined expr_type

  and type_of_object_property outlined = function
    | loc, OInit (key, expr_type) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Init (type_of_expr_type outlined expr_type);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })
    | loc, OMethod (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Init (type_of_function outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = true;
        variance = None;
      })
    | loc, OGet (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Get (type_of_function_t outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })
    | loc, OSet (key, function_t) -> Ast.Type.Object.Property (loc, {
        Ast.Type.Object.Property.key;
        value = Ast.Type.Object.Property.Set (type_of_function_t outlined function_t);
        optional = false;
        static = false;
        proto = false;
        _method = false;
        variance = None;
      })

  and type_of_function_t outlined = function
    | loc, FUNCTION {
        tparams: (Loc.t, Loc.t) Ast.Type.ParameterDeclaration.t option;
        params: function_params;
        return: little_annotation;
      } ->
      let params_loc, params, rest = params in
      loc, {
        Ast.Type.Function.tparams;
        params = params_loc, {
          Ast.Type.Function.Params.params = Core_list.map ~f:param_of_type params;
          rest = match rest with
            | None -> None
            | Some (loc, rest) -> Some (loc, {
                Ast.Type.Function.RestParam.argument = param_of_type rest
              })
        };
        return = type_of_little_annotation outlined return;
      }

  and type_of_function outlined function_t =
    let loc, function_t = type_of_function_t outlined function_t in
    loc, Ast.Type.Function function_t

  and type_of_little_annotation outlined = function
    | TYPE t -> t
    | EXPR expr_type -> type_of_expr_type outlined expr_type

  and annot_of_little_annotation outlined little_annotation =
    let t = type_of_little_annotation outlined little_annotation in
    fst t, t

  and name_opt_pattern id name_opt =
    let id_pattern = fst id, Ast.Pattern.Identifier {
      Ast.Pattern.Identifier.name = id;
      annot = Ast.Type.Missing (fst id);
      optional = false;
    } in
    match name_opt with
      | None -> id_pattern
      | Some (name, names) ->
        let pattern = fst name, Ast.Pattern.Object {
          Ast.Pattern.Object.properties = [
            Ast.Pattern.Object.Property (fst name, {
              Ast.Pattern.Object.Property.key = Ast.Pattern.Object.Property.Identifier name;
              pattern = id_pattern;
              shorthand = (snd id = snd name);
            })
          ];
          annot = Ast.Type.Missing (fst name);
        } in
        wrap_name_pattern pattern names

  and wrap_name_pattern pattern = function
    | [] -> pattern
    | name::names ->
      let pattern = fst name, Ast.Pattern.Object {
        Ast.Pattern.Object.properties = [
          Ast.Pattern.Object.Property (fst name, {
            Ast.Pattern.Object.Property.key = Ast.Pattern.Object.Property.Identifier name;
            pattern;
            shorthand = false;
          })
        ];
        annot = Ast.Type.Missing (fst name);
      } in
      wrap_name_pattern pattern names

  and stmt_of_decl outlined decl_loc id = function
    | Type { tparams; right; } ->
      decl_loc, Ast.Statement.TypeAlias { Ast.Statement.TypeAlias.id; tparams; right }
    | OpaqueType { tparams; supertype; } ->
      decl_loc, Ast.Statement.DeclareOpaqueType {
        Ast.Statement.OpaqueType.id; tparams; impltype = None; supertype
      }
    | Interface { tparams; extends; body; } ->
      decl_loc, Ast.Statement.InterfaceDeclaration { Ast.Statement.Interface.id; tparams; extends; body }
    | ClassDecl (CLASS { tparams; extends; implements; body = (body_loc, body) }) ->
      let body = body_loc, {
        Ast.Type.Object.exact = false;
        inexact = false;
        properties = Core_list.map ~f:(object_type_property_of_class_element outlined) body;
      } in
      let mixins = [] in
      decl_loc, Ast.Statement.DeclareClass {
        Ast.Statement.DeclareClass.id; tparams; extends; implements; mixins; body;
      }
    | ClassDecl (DECLARE_CLASS { tparams; extends; mixins; implements; body }) ->
      decl_loc, Ast.Statement.DeclareClass {
        Ast.Statement.DeclareClass.id; tparams; extends; implements; mixins; body;
      }
    | FunctionDecl little_annotation ->
      decl_loc, Ast.Statement.DeclareFunction {
        Ast.Statement.DeclareFunction.id;
        annot = annot_of_little_annotation outlined little_annotation;
        predicate = None;
      }
    | VariableDecl little_annotation ->
      decl_loc, Ast.Statement.DeclareVariable {
        Ast.Statement.DeclareVariable.id;
        annot = Ast.Type.Available (annot_of_little_annotation outlined little_annotation)
      }
    | ImportNamed { kind; source; name; } ->
      let importKind = kind in
      let source = source_of_source source in
      let default = if snd name = "default" then Some id else None in
      let specifiers =
        if snd name = "default" then None else
          Some (Ast.Statement.ImportDeclaration.ImportNamedSpecifiers [{
            Ast.Statement.ImportDeclaration.kind = None;
            local = if snd id = snd name then None else Some id;
            remote = name;
          }]) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
          specifiers;
      }
    | ImportStar { kind; source; } ->
      let importKind = kind in
      let source = source_of_source source in
      let default = None in
      let specifiers =
        Some (Ast.Statement.ImportDeclaration.ImportNamespaceSpecifier (fst id, id)) in
      decl_loc, Ast.Statement.ImportDeclaration {
        Ast.Statement.ImportDeclaration.importKind;
        source;
        default;
        specifiers;
      }
    | Require { source; name } ->
      let kind = Ast.Statement.VariableDeclaration.Const in
      let pattern = name_opt_pattern id name in
      let loc, x = source in
      let require = decl_loc, Ast.Expression.Call {
        Ast.Expression.Call.callee =
          approx_loc decl_loc, Ast.Expression.Identifier (approx_loc decl_loc, "require");
        targs = None;
        arguments = [Ast.Expression.Expression (loc, Ast.Expression.Literal {
          Ast.Literal.value = Ast.Literal.String x;
          raw = x;
        })];
      } in
      let declaration = {
        Ast.Statement.VariableDeclaration.Declarator.id = pattern;
        init = Some require;
      } in
      decl_loc, Ast.Statement.VariableDeclaration {
        Ast.Statement.VariableDeclaration.kind;
        declarations = [decl_loc, declaration];
      }

  and object_type_property_of_class_element outlined = function
    | loc, CMethod (object_key, _kind, static, f) ->
      let open Ast.Type.Object in
      Property (loc, {
        Property.key = object_key;
        value = Property.Init (type_of_function outlined f);
        optional = false;
        static;
        proto = false;
        _method = true;
        variance = None;
      })
    | loc, CProperty (object_key, static, variance, t) ->
      let open Ast.Type.Object in
      Property (loc, {
        Property.key = object_key;
        value = Property.Init t;
        optional = false;
        static;
        proto = false;
        _method = false;
        variance;
      })
    | _loc, CPrivateField (_x, _static, _variance, _t) -> assert false

end

(* A signature of a module is described by exported expressions / definitions, but what we're really
   interested in is their types. In particular, we are interested in computing these types early, so
   that we can check the code inside a module against the signature in a separate pass. So the
   question is: what information is necessary to compute these types?

   Assuming we know how to map various kinds of type constructors (and destructors) to their
   meanings, all that remains to verify is that the types are well-formed: any identifiers appearing
   inside them should be defined in the top-level local scope, or imported, or global; and their
   "sort" of use (as a type or as a value) must match up with their definition.

   We break up the verification of well-formedness by computing a set of "dependencies" found by
   walking the structure of types, definitions, and expressions. The dependencies are simply the
   identifiers that are reached in this walk, coupled with their sort of use. Elsewhere, we
   recursively expand these dependencies by looking up the definitions of such identifiers, possibly
   uncovering further dependencies, and so on.

   A couple of important things to note at this point.

   1. The verification of well-formedness (and computation of types) is complete only up to the
   top-level local scope: any identifiers that are imported or global need to be resolved in a
   separate phase that builds things up in module-dependency order. To reflect this arrangement,
   verification returns not only a set of immediate errors but a set of conditions on imported and
   global identifiers that must be enforced by that separate phase.

   2. There is a fine line between errors found during verification and errors found during the
   computation of types (since both kinds of errors are static errors). Still, one might argue that
   the verification step should ensure that the computation step never fails. In that regard, the
   checks we have so far are not enough. In particular:

   (a) While classes are intended to be the only values that can be used as types, we also allow
   variables to be used as types, to account for the fact that a variable could be bound to a
   top-level local, imported, or global class. Ideally we would verify that these expectation is
   met, but we don't yet.

   (b) While destructuring only makes sense on types of the corresponding kinds (e.g., object
   destructuring would only work on object types), currently we allow destructuring on all
   types. Again, ideally we would discharge verification conditions for these and ensure that they
   are satisfied.

   (c) Parts of the module system are still under design. For example, can types be defined locally
   in anything other than the top-level scope? Do (or under what circumstances do) `require` and
   `import *` bring exported types in scope? These considerations will affect the computation step
   and ideally would be verified as well, but we're punting on them right now.
*)
module Eval(Env: Signature_builder_verify.EvalEnv) = struct

  let rec type_ t = t

  and type_params tparams = tparams

  and object_key key = key

  and object_type ot = ot

  and generic tr = tr

  and type_args = function
    | None -> None
    | Some (loc, ts) -> Some (loc, Core_list.map ~f:(type_) ts)

  let rec annot_path = function
    | Kind.Annot_path.Annot (_, t) -> type_ t
    | Kind.Annot_path.Object (path, _) -> annot_path path

  let rec init_path = function
    | Kind.Init_path.Init expr -> literal_expr expr
    | Kind.Init_path.Object (prop_loc, (path, (loc, x))) ->
      let expr_type = init_path path in
      prop_loc, match expr_type with
        | path_loc, T.ValueRef reference -> T.ValueRef (T.RPath (path_loc, reference, (loc, x)))
        | _ -> T.ObjectDestruct (expr_type, (loc, x))

  and annotation loc ?init annot =
    match annot with
      | Some path -> T.TYPE (annot_path path)
      | None ->
        begin match init with
          | Some path -> T.EXPR (init_path path)
          | None -> T.FixMe.mk_little_annotation loc
        end

  and annotated_type = function
    | Ast.Type.Missing loc -> T.FixMe.mk_type loc
    | Ast.Type.Available (_, t) -> type_ t

  and pattern ?(default=false) patt =
    let open Ast.Pattern in
    match patt with
      | loc, Identifier { Identifier.annot; name; optional; } ->
        loc, Some name, default || optional, annotated_type annot
      | loc, Object { Object.annot; properties = _ } ->
        if default
        then loc, Some (loc, "_"), true, annotated_type annot
        else loc, None, false, annotated_type annot
      | loc, Array { Array.annot; elements = _ } ->
        if default
        then loc, Some (loc, "_"), true, annotated_type annot
        else loc, None, false, annotated_type annot
      | _, Assignment { Assignment.left; right = _ } -> pattern ~default:true left
      | loc, Expression _ ->
        T.FixMe.mk_pattern default loc

  and literal_expr =
    let open Ast.Expression in
    function
      | loc, Literal { Ast.Literal.value; raw } ->
        begin match value with
          | Ast.Literal.String value -> loc, T.StringLiteral { Ast.StringLiteral.value; raw }
          | Ast.Literal.Number value -> loc, T.NumberLiteral { Ast.NumberLiteral.value; raw }
          | Ast.Literal.Boolean b -> loc, T.BooleanLiteral b
          | Ast.Literal.Null -> loc, T.Null
          | _ -> T.FixMe.mk_expr_type loc
        end
      | loc, TemplateLiteral _ -> loc, T.String
      | loc, Identifier stuff -> loc, T.ValueRef (identifier stuff)
      | loc, Class stuff ->
        let open Ast.Class in
        let {
          tparams; body; extends; implements;
          id; classDecorators = _
        } = stuff in
        let super, super_targs = match extends with
          | None -> None, None
          | Some (_, { Extends.expr; targs; }) -> Some expr, targs in
        loc, T.Outline (T.Class (id, class_ tparams body super super_targs implements))
      | loc, Function stuff
      | loc, ArrowFunction stuff
        ->
        let open Ast.Function in
        let {
          generator; tparams; params; return; body;
          id = _; async = _; predicate = _; sig_loc = _;
        } = stuff in
        loc, T.Function (function_ generator tparams params return body)
      | loc, Object stuff ->
        let open Ast.Expression.Object in
        let { properties } = stuff in
        begin match object_ properties with
          | Some o -> loc, T.ObjectLiteral { frozen = false; properties = o }
          | None -> T.FixMe.mk_expr_type loc
        end
      | loc, Array stuff ->
        let open Ast.Expression.Array in
        let { elements } = stuff in
        begin match array_ elements with
          | Some a -> loc, T.ArrayLiteral a
          | None -> T.FixMe.mk_expr_type loc
        end
      | loc, TypeCast stuff ->
        let open Ast.Expression.TypeCast in
        let { annot; expression = _ } = stuff in
        let _, t = annot in
        loc, T.TypeCast (type_ t)
      | loc, Member stuff ->
        begin match member stuff with
          | Some ref_expr -> loc, T.ValueRef ref_expr
          | None -> T.FixMe.mk_expr_type loc
        end
      | loc, Import (source_loc,
         (Literal { Ast.Literal.value = Ast.Literal.String value; raw } |
          TemplateLiteral {
            TemplateLiteral.quasis = [_, {
              TemplateLiteral.Element.value = { TemplateLiteral.Element.cooked = value; raw }; _
            }]; _
          })) ->
        loc, T.Outline (T.DynamicImport (source_loc, { Ast.StringLiteral.value; raw }))
      | (loc, Call { Ast.Expression.Call.callee = (_, Identifier (_, "require")); _ }) as expr ->
        loc, T.Outline (T.DynamicRequire expr)
      | _, Call {
          Ast.Expression.Call.
          callee = (_, Member {
            Ast.Expression.Member._object = (_, Identifier (_, "Object"));
            property = Ast.Expression.Member.PropertyIdentifier (_, "freeze");
          });
          targs = None;
          arguments = [Expression (loc, Object stuff)]
        } ->
        let open Ast.Expression.Object in
        let { properties } = stuff in
        begin match object_ properties with
          | Some o -> loc, T.ObjectLiteral { frozen = true; properties = o }
          | None -> T.FixMe.mk_expr_type loc
        end
      | loc, Unary stuff ->
        let open Ast.Expression.Unary in
        let { operator; argument } = stuff in
        arith_unary operator loc argument
      | loc, Binary stuff ->
        let open Ast.Expression.Binary in
        let { operator; left; right } = stuff in
        arith_binary operator loc left right
      | loc, Sequence stuff ->
        let open Ast.Expression.Sequence in
        let { expressions } = stuff in
        begin match List.rev expressions with
          | expr::_ -> literal_expr expr
          | [] -> T.FixMe.mk_expr_type loc
        end
      | loc, Assignment stuff ->
        let open Ast.Expression.Assignment in
        let { operator; left = _; right } = stuff in
        begin match operator with
          | Assign -> literal_expr right
          | _ -> T.FixMe.mk_expr_type loc
        end
      | loc, Update stuff ->
        let open Ast.Expression.Update in
        (* This operation has a simple result type. *)
        let { operator = _; argument = _; prefix = _ } = stuff in
        loc, T.Number

      | loc, Call _
      | loc, Comprehension _
      | loc, Conditional _
      | loc, Generator _
      | loc, Import _
      | loc, JSXElement _
      | loc, JSXFragment _
      | loc, Logical _
      | loc, MetaProperty _
      | loc, New _
      | loc, OptionalCall _
      | loc, OptionalMember _
      | loc, Super
      | loc, TaggedTemplate _
      | loc, This
      | loc, Yield _
        -> T.FixMe.mk_expr_type loc

  and identifier stuff =
    let loc, name = stuff in
    T.RLexical (loc, name)

  and member stuff =
    let open Ast.Expression.Member in
    let { _object; property } = stuff in
    let ref_expr_opt = ref_expr _object in
    let name_opt = match property with
      | PropertyIdentifier (loc, x) -> Some (loc, x)
      | PropertyPrivateName (_, (loc, x)) -> Some (loc, x)
      | PropertyExpression _ -> None
    in
    match ref_expr_opt, name_opt with
      | Some (path_loc, t), Some name -> Some (T.RPath (path_loc, t, name))
      | None, _ | _, None -> None

  and ref_expr expr =
    let open Ast.Expression in
    match expr with
      | loc, Identifier stuff -> Some (loc, identifier stuff)
      | loc, Member stuff ->
        begin match member stuff with
          | Some ref_expr -> Some (loc, ref_expr)
          | None -> None
        end
      | _ -> None

  and arith_unary operator loc _argument =
    let open Ast.Expression.Unary in
    match operator with
      (* These operations have simple result types. *)
      | Minus -> loc, T.Number
      | Plus -> loc, T.Number
      | Not -> loc, T.Boolean
      | BitNot -> loc, T.Number
      | Typeof -> loc, T.String
      | Void -> loc, T.Void
      | Delete -> loc, T.Boolean

      | Await ->
        (* The result type of this operation depends in a complicated way on the argument type. *)
        T.FixMe.mk_expr_type loc

  and arith_binary operator loc _left _right =
    let open Ast.Expression.Binary in
    match operator with
      | Plus ->
        (* The result type of this operation depends in a complicated way on the argument type. *)
        T.FixMe.mk_expr_type loc
      (* These operations have simple result types. *)
      | Equal -> loc, T.Boolean
      | NotEqual -> loc, T.Boolean
      | StrictEqual -> loc, T.Boolean
      | StrictNotEqual -> loc, T.Boolean
      | LessThan -> loc, T.Boolean
      | LessThanEqual -> loc, T.Boolean
      | GreaterThan -> loc, T.Boolean
      | GreaterThanEqual -> loc, T.Boolean
      | LShift -> loc, T.Number
      | RShift -> loc, T.Number
      | RShift3 -> loc, T.Number
      | Minus -> loc, T.Number
      | Mult -> loc, T.Number
      | Exp -> loc, T.Number
      | Div -> loc, T.Number
      | Mod -> loc, T.Number
      | BitOr -> loc, T.Number
      | Xor -> loc, T.Number
      | BitAnd -> loc, T.Number
      | In -> loc, T.Boolean
      | Instanceof -> loc, T.Boolean

  and function_ =
    let function_param (_, { Ast.Function.Param.argument }) =
      pattern argument

    in let function_rest_param (loc, { Ast.Function.RestParam.argument }) =
      (loc, pattern argument)

    in let function_params params =
      let open Ast.Function in
      let params_loc, { Params.params; rest; } = params in
      let params = Core_list.map ~f:function_param params in
      let rest = match rest with
        | None -> None
        | Some param -> Some (function_rest_param param) in
      params_loc, params, rest

    in fun generator tparams params return body ->
      let tparams = type_params tparams in
      let params = function_params params in
      let return = match return with
        | Ast.Type.Missing loc ->
          if not generator && Signature_utils.Procedure_decider.is body then T.EXPR (loc, T.Void)
          else T.FixMe.mk_little_annotation loc
        | Ast.Type.Available (_, t) -> T.TYPE (type_ t) in
      (* TODO: It is unclear whether what happens for async or generator functions. In particular,
         what do declarations of such functions look like, aside from the return type being
         `Promise<...>` or `Generator<...>`? *)
      T.FUNCTION {
        tparams;
        params;
        return
      }

  and class_ =
    let class_element acc element =
      let open Ast.Class in
      match element with
        | Body.Method (_, { Method.key = (Ast.Expression.Object.Property.Identifier (_, name)); _ })
        | Body.Property (_, { Property.key = (Ast.Expression.Object.Property.Identifier (_, name)); _ })
            when not Env.prevent_munge && Signature_utils.is_munged_property_name name ->
          acc
        | Body.Property (_, {
            Property.key = (Ast.Expression.Object.Property.Identifier (_, "propTypes"));
            static = true; _
          }) when Env.ignore_static_propTypes ->
          acc

        | Body.Method (elem_loc, { Method.key; value; kind; static; decorators = _ }) ->
          let x = object_key key in
          let loc, {
            Ast.Function.generator; tparams; params; return; body;
            id = _; async = _; predicate = _; sig_loc = _;
          } = value in
          (elem_loc, T.CMethod
            (x, kind, static, (loc, function_ generator tparams params return body))) :: acc
        | Body.Property (elem_loc, { Property.key; annot; static; variance; value = _ }) ->
          let x = object_key key in
          (elem_loc, T.CProperty (x, static, variance, annotated_type annot)) :: acc
        | Body.PrivateField (elem_loc, {
            PrivateField.key = (_, (_, x)); annot; static; variance; value = _
          }) ->
          (elem_loc, T.CPrivateField (x, static, variance, annotated_type annot)) :: acc

    in fun tparams body super super_targs implements ->
      let open Ast.Class in
      let body_loc, { Body.body } = body in
      let tparams = type_params tparams in
      let body = List.rev @@ List.fold_left class_element [] body in
      let extends = match super with
        | None -> None
        | Some expr ->
          let ref_expr_opt = ref_expr expr in
          begin match ref_expr_opt with
            | Some (loc, reference) -> Some (loc, {
                Ast.Type.Generic.id = T.generic_id_of_reference reference;
                targs = type_args super_targs;
              })
            | None -> T.FixMe.mk_extends (fst expr)
          end
      in
      let implements = Core_list.map ~f:class_implement implements in
      T.CLASS {
        tparams;
        extends;
        implements;
        body = body_loc, body;
      }

  and array_ =
    let array_element expr_or_spread_opt =
      let open Ast.Expression in
      match expr_or_spread_opt with
        | None -> assert false
        | Some (Expression expr) -> T.AInit (literal_expr expr)
        | Some (Spread _spread) -> assert false
    in
    function
      | [] -> None
      | t::ts ->
        try Some (Nel.map array_element (t, ts))
        with _ -> None

  and class_implement implement = implement

  and object_ =
    let object_property =
      let open Ast.Expression.Object.Property in
      function
        | loc, Init { key; value; shorthand = _ } ->
          let x = object_key key in
          loc, T.OInit (x, literal_expr value)
        | loc, Method { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let {
            generator; tparams; params; return; body;
            id = _; async = _; predicate = _; sig_loc = _;
          } = fn in
          loc, T.OMethod (x, (fn_loc, function_ generator tparams params return body))
        | loc, Get { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let {
            generator; tparams; params; return; body;
            id = _; async = _; predicate = _; sig_loc = _;
          } = fn in
          loc, T.OGet (x, (fn_loc, function_ generator tparams params return body))
        | loc, Set { key; value = (fn_loc, fn) } ->
          let x = object_key key in
          let open Ast.Function in
          let {
            generator; tparams; params; return; body;
            id = _; async = _; predicate = _; sig_loc = _;
          } = fn in
          loc, T.OSet (x, (fn_loc, function_ generator tparams params return body))
    in
    function
      | [] -> None
      | property::properties ->
        let open Ast.Expression.Object in
        try Some (Nel.map (function
          | Property p -> object_property p
          | SpreadProperty _p -> assert false
        ) (property, properties))
        with _ -> None

end

module Generator(Env: Signature_builder_verify.EvalEnv) = struct

  module Eval = Eval(Env)

  let eval (loc, kind) =
    match kind with
      | Kind.VariableDef { annot; init } ->
        T.VariableDecl (Eval.annotation loc ?init annot)
      | Kind.FunctionDef { generator; tparams; params; return; body; } ->
        T.FunctionDecl (T.EXPR
          (loc, T.Function (Eval.function_ generator tparams params return body)))
      | Kind.DeclareFunctionDef { annot = (_, t) } ->
        T.FunctionDecl (T.TYPE (Eval.type_ t))
      | Kind.ClassDef { tparams; body; super; super_targs; implements } ->
        T.ClassDecl (Eval.class_ tparams body super super_targs implements)
      | Kind.DeclareClassDef { tparams; body = (body_loc, body); extends; mixins; implements } ->
        let tparams = Eval.type_params tparams in
        let body = Eval.object_type body in
        let extends = match extends with
          | None -> None
          | Some r -> Some (Eval.generic r) in
        let mixins = Core_list.map ~f:(Eval.generic) mixins in
        let implements = Core_list.map ~f:Eval.class_implement implements in
        T.ClassDecl (T.DECLARE_CLASS {
          tparams;
          extends;
          mixins;
          implements;
          body = body_loc, body;
        })
      | Kind.TypeDef { tparams; right } ->
        let tparams = Eval.type_params tparams in
        let right = Eval.type_ right in
        T.Type {
          tparams;
          right;
        }
      | Kind.OpaqueTypeDef { tparams; supertype } ->
        let tparams = Eval.type_params tparams in
        let supertype = match supertype with
          | None -> None
          | Some t -> Some (Eval.type_ t)
        in
        T.OpaqueType {
          tparams;
          supertype;
        }
      | Kind.InterfaceDef { tparams; extends; body = (body_loc, body) } ->
        let tparams = Eval.type_params tparams in
        let extends = Core_list.map ~f:(Eval.generic) extends in
        let body = Eval.object_type body in
        T.Interface {
          tparams;
          extends;
          body = body_loc, body;
        }
      | Kind.ImportNamedDef { kind; source; name } ->
        T.ImportNamed { kind; source; name }
      | Kind.ImportStarDef { kind; source } ->
        T.ImportStar { kind; source }
      | Kind.RequireDef { source; name } ->
        T.Require { source; name }
      | Kind.SketchyToplevelDef ->
        T.FixMe.mk_decl loc

  let make_env outlined env =
    SMap.fold (fun n entries acc ->
      Utils_js.LocMap.fold (fun loc kind acc ->
        let id = loc, n in
        let dt = eval kind in
        let decl_loc = fst kind in
        (T.stmt_of_decl outlined decl_loc id dt) :: acc
      ) entries acc
    ) env []

  let cjs_exports outlined =
    function
      | None, [] -> []
      | Some mod_exp_loc, [File_sig.DeclareModuleExportsDef (loc, t)] ->
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (loc, t)]
      | Some mod_exp_loc, [File_sig.SetModuleExportsDef expr] ->
        let annot = T.type_of_expr_type outlined (Eval.literal_expr expr) in
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (fst annot, annot)]
      | Some mod_exp_loc, list ->
        let properties =
          try Core_list.map ~f:(function
          | File_sig.AddModuleExportsDef (id, expr) ->
            let annot = T.type_of_expr_type outlined (Eval.literal_expr expr) in
            let open Ast.Type.Object in
            Property (fst id, {
              Property.key = Ast.Expression.Object.Property.Identifier id;
              value = Property.Init annot;
              optional = false;
              static = false;
              proto = false;
              _method = true;
              variance = None;
            })
          | _ -> assert false
          ) list
          with _ -> [] in
        let ot = {
          Ast.Type.Object.exact = true;
          inexact = false;
          properties;
        } in
        let t = mod_exp_loc, Ast.Type.Object ot in
        [mod_exp_loc, Ast.Statement.DeclareModuleExports (mod_exp_loc, t)]
      | _ -> []

  let eval_entry (id, kind) =
    id, eval kind

  let eval_declare_variable loc declare_variable =
    eval_entry (Entry.declare_variable loc declare_variable)

  let eval_declare_function loc declare_function =
    eval_entry (Entry.declare_function loc declare_function)

  let eval_declare_class loc declare_class =
    eval_entry (Entry.declare_class loc declare_class)

  let eval_type_alias loc type_alias =
    eval_entry (Entry.type_alias loc type_alias)

  let eval_opaque_type loc opaque_type =
    eval_entry (Entry.opaque_type loc opaque_type)

  let eval_interface loc interface =
    eval_entry (Entry.interface loc interface)

  let eval_function_declaration loc function_declaration =
    eval_entry (Entry.function_declaration loc function_declaration)

  let eval_class loc class_ =
    eval_entry (Entry.class_ loc class_)

  let eval_variable_declaration loc variable_declaration =
    Core_list.map ~f:eval_entry @@
      Entry.variable_declaration loc variable_declaration

  let eval_export_default_declaration = Ast.Statement.ExportDefaultDeclaration.(function
    | Declaration (loc, Ast.Statement.FunctionDeclaration
        ({ Ast.Function.id = Some _; _ } as function_declaration)
      ) ->
      `Decl (Entry.function_declaration loc function_declaration)
    | Declaration (loc, Ast.Statement.FunctionDeclaration ({
        Ast.Function.id = None;
        generator; tparams; params; return; body;
        async = _; predicate = _; sig_loc = _;
      })) ->
      `Expr (loc, T.Function (Eval.function_ generator tparams params return body))
    | Declaration (loc, Ast.Statement.ClassDeclaration ({ Ast.Class.id = Some _; _ } as class_)) ->
      `Decl (Entry.class_ loc class_)
    | Declaration (loc, Ast.Statement.ClassDeclaration ({
        Ast.Class.id = None;
        tparams; body; extends; implements;
        classDecorators = _
      })) ->
      let super, super_targs = match extends with
        | None -> None, None
        | Some (_, { Ast.Class.Extends.expr; targs; }) -> Some expr, targs in
      `Expr (loc, T.Outline (T.Class (None, Eval.class_ tparams body super super_targs implements)))
    | Declaration _stmt -> assert false
    | Expression (loc, Ast.Expression.Function ({ Ast.Function.id = Some _; _ } as function_)) ->
      `Decl (Entry.function_declaration loc function_)
    | Expression expr -> `Expr (Eval.literal_expr expr)
  )

  let export_name export_loc ?exported ?source local exportKind =
    export_loc, Ast.Statement.ExportNamedDeclaration {
      Ast.Statement.ExportNamedDeclaration.declaration = None;
      specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportSpecifiers [
        approx_loc export_loc, {
          Ast.Statement.ExportNamedDeclaration.ExportSpecifier.local; exported;
        }
      ]);
      source;
      exportKind;
    }

  let export_named_specifier export_loc local remote source exportKind =
    let exported = if snd remote = snd local then None else Some remote in
    let source = match source with
      | None -> None
      | Some source -> Some (T.source_of_source source) in
    export_name export_loc ?exported ?source local exportKind

  let export_star export_loc star_loc ?remote source exportKind =
    export_loc, Ast.Statement.ExportNamedDeclaration {
      Ast.Statement.ExportNamedDeclaration.declaration = None;
      specifiers = Some (Ast.Statement.ExportNamedDeclaration.ExportBatchSpecifier (
        star_loc, remote
      ));
      source = Some (T.source_of_source source);
      exportKind;
    }

  let declare_export_default_declaration export_loc default_loc declaration =
    export_loc, Ast.Statement.DeclareExportDeclaration {
      default = Some default_loc;
      Ast.Statement.DeclareExportDeclaration.declaration = Some declaration;
      specifiers = None;
      source = None;
    }

  let export_value_named_declaration export_loc local =
    export_name export_loc local Ast.Statement.ExportValue

  let export_value_default_named_declaration export_loc default local =
    export_name export_loc local ~exported:default Ast.Statement.ExportValue

  let export_value_named_specifier export_loc local remote source =
    export_named_specifier export_loc local remote source Ast.Statement.ExportValue

  let export_value_star export_loc star_loc source =
    export_star export_loc star_loc source Ast.Statement.ExportValue

  let export_value_ns_star export_loc star_loc ns source =
    export_star export_loc star_loc ~remote:ns source Ast.Statement.ExportValue

  let export_type_named_declaration export_loc local =
    export_name export_loc local Ast.Statement.ExportType

  let export_type_named_specifier export_loc local remote source =
    export_named_specifier export_loc local remote source Ast.Statement.ExportType

  let export_type_star export_loc star_loc source =
    export_star export_loc star_loc source Ast.Statement.ExportType


  let eval_export_value_bindings outlined named named_infos star =
    let open File_sig in
    let named, ns = List.partition (function
      | _, (_, ExportNamed { kind = NamedSpecifier _; _ })
      | _, (_, ExportNs _)
        -> false
      | _, (_, _) -> true
    ) named in
    let stmts = List.fold_left (fun acc -> function
      | export_loc, ExportStar { star_loc; source; } ->
        (export_value_star export_loc star_loc source) :: acc
    ) [] star in
    let seen = ref SSet.empty in
    let stmts = List.fold_left2 (fun acc (n, (export_loc, export)) export_def ->
      if SSet.mem n !seen then acc else (
        seen := SSet.add n !seen;
        match export, export_def with
        | ExportDefault { default_loc; local }, DeclareExportDef decl ->
          begin match local with
            | Some id ->
              (export_value_default_named_declaration export_loc (default_loc, n) id) :: acc
            | None ->
              (declare_export_default_declaration export_loc default_loc decl) :: acc
          end
        | ExportDefault { default_loc; _ }, ExportDefaultDef decl ->
          begin match eval_export_default_declaration decl with
            | `Decl (id, _kind) ->
              (export_value_default_named_declaration export_loc (default_loc, n) id) :: acc
            | `Expr expr_type ->
              let declaration = Ast.Statement.DeclareExportDeclaration.DefaultType
                (T.type_of_expr_type outlined expr_type) in
              (declare_export_default_declaration export_loc default_loc declaration) :: acc
          end
        | ExportNamed { loc; kind = NamedDeclaration }, DeclareExportDef _decl ->
          (export_value_named_declaration export_loc (loc, n)) :: acc
        | ExportNamed { loc; kind = NamedDeclaration }, ExportNamedDef _stmt ->
          (export_value_named_declaration export_loc (loc, n)) :: acc
        | _ -> assert false
      )
    ) stmts named named_infos in
    List.fold_left (fun acc (n, (export_loc, export)) ->
      match export with
        | ExportNamed { loc; kind = NamedSpecifier { local = name; source } } ->
          (export_value_named_specifier export_loc name (loc, n) source) :: acc
        | ExportNs { loc; star_loc; source; } ->
          (export_value_ns_star export_loc star_loc (loc, n) source) :: acc
        | _ -> assert false
    ) stmts ns

  let eval_export_type_bindings type_named type_named_infos type_star =
    let open File_sig in
    let type_named, type_ns = List.partition (function
      | _, (_, TypeExportNamed { kind = NamedSpecifier _; _ }) -> false
      | _, (_, _) -> true
    ) type_named in
    let stmts = List.fold_left (fun acc -> function
      | export_loc, ExportStar { star_loc; source } ->
        (export_type_star export_loc star_loc source) :: acc
    ) [] type_star in
    let stmts = List.fold_left2 (fun acc (n, (export_loc, export)) export_def ->
      (match export, export_def with
        | TypeExportNamed { loc; kind = NamedDeclaration }, DeclareExportDef _decl ->
          export_type_named_declaration export_loc (loc, n)
        | TypeExportNamed { loc; kind = NamedDeclaration }, ExportNamedDef _stmt ->
          export_type_named_declaration export_loc (loc, n)
        | _ -> assert false
      ) :: acc
    ) stmts type_named type_named_infos in
    List.fold_left (fun acc (n, (export_loc, export)) ->
      (match export with
      | TypeExportNamed { loc; kind = NamedSpecifier { local = name; source } } ->
          export_type_named_specifier export_loc name (loc, n) source
        | _ -> assert false
      ) :: acc
    ) stmts type_ns


  let exports outlined file_sig =
    let open File_sig in
    let module_sig = file_sig.module_sig in
    let {
      info = exports_info;
      module_kind;
      type_exports_named;
      type_exports_star;
      requires = _;
    } = module_sig in
    let { module_kind_info; type_exports_named_info } = exports_info in
    let values = match module_kind, module_kind_info with
      | CommonJS { mod_exp_loc }, CommonJSInfo cjs_exports_defs ->
        cjs_exports outlined (mod_exp_loc, cjs_exports_defs)
      | ES { named; star }, ESInfo named_infos ->
        eval_export_value_bindings outlined named named_infos star
      | _ -> assert false
    in
    let types = eval_export_type_bindings type_exports_named type_exports_named_info type_exports_star in
    values, types

  let relativize loc program_loc =
    Loc.{ program_loc with
      start = {
        line = program_loc._end.line + loc.start.line;
        column = loc.start.column;
        offset = 0;
      };
      _end = {
        line = program_loc._end.line + loc._end.line;
        column = loc._end.column;
        offset = 0;
      };
    }

  let make env file_sig program =
    let program_loc, _, comments = program in
    let outlined = T.Outlined.create () in
    let env = make_env outlined env in
    let values, types = exports outlined file_sig in
    let outlined_stmts = T.Outlined.get outlined in
    program_loc,
    List.sort Pervasives.compare (
      List.rev_append env @@
      List.rev outlined_stmts
    ) @ List.sort Pervasives.compare (
      List.rev_append values @@
      List.rev types
    ),
    comments

end
