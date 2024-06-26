module L = Llvm
open Ast
open Sast

let _ = L.enable_pretty_stacktrace()
module StringMap = Map.Make(String)
module BindMap = Map.Make(struct type t = Ast.bind let compare = Pervasives.compare end)
module SfdeclMap = Map.Make(struct type t = Sast.sfunc_decl let compare = Pervasives.compare end)

let explode s = 
    let rec aux out n =
        match n with
            | 0 -> out
            | _ -> aux ((String.get s (n - 1)) :: out) (n - 1) in
    aux [] (String.length s)

type data =
    |Raw of L.llvalue
    |Box of L.llvalue

type dataunit_addr = 
    |RawAddr of L.llvalue
    |BoxAddr of L.llvalue * bool

type state = {
    namespace: dataunit_addr BindMap.t;
    func: L.llvalue;
    ret_typ: typ;
    b: L.llbuilder;
    optim_funcs: L.llvalue SfdeclMap.t;
    generic_func: bool;
}

type state_component = 
    | S_names of dataunit_addr BindMap.t
    | S_rettyp of typ
    | S_func of L.llvalue
    | S_b of L.llbuilder
    | S_optimfuncs of L.llvalue SfdeclMap.t
    | S_needs_reboxing of string * bool
    | S_generic_func of bool
    | S_list of state_component list

let seq len =
  let rec aux len acc =
    if len < 0 then acc else aux (len - 1) (len::acc)
  in aux (len - 1) []

type binop_builder = ((L.llvalue -> L.llvalue -> string -> L.llbuilder -> L.llvalue) * L.lltype)
type call_builder = ((L.llvalue -> L.llvalue array -> string -> L.llbuilder -> L.llvalue) * L.lltype)
type unop_builder = ((L.llvalue -> string -> L.llbuilder -> L.llvalue) * L.lltype)

type oprt =
  | Oprt of
      string * binop_builder option * binop_builder option * binop_builder option * binop_builder option * binop_builder option * binop_builder option * binop_builder option
  | Coprt of
      string * call_builder option * call_builder option * call_builder option * call_builder option * call_builder option * call_builder option * call_builder option
  | Uoprt of
      string * unop_builder option * unop_builder option * unop_builder option * unop_builder option * unop_builder option * unop_builder option * unop_builder option

type built_oprt =
  | BOprt of string * (((L.llvalue * L.llbuilder) * ((L.llvalue -> L.llvalue -> string -> L.llbuilder -> L.llvalue) * L.lltype)) option)
  | BCoprt of string * (((L.llvalue * L.llbuilder) * ((L.llvalue -> L.llvalue array -> string -> L.llbuilder -> L.llvalue) * L.lltype)) option)
  | BUoprt of string * (((L.llvalue * L.llbuilder) * ((L.llvalue -> string -> L.llbuilder -> L.llvalue) * L.lltype)) option)
let exceptions = ref true

let initial_list_size = 0
let list_growth_factor = 2

let translate prgm except =
  exceptions := except;

  let context = L.global_context () in
  
  let the_module = L.create_module context "Spython" in
  let pm() = L.dump_module the_module in

  let int_t      = L.i32_type    context
  and float_t    = L.double_type context
  and bool_t     = L.i1_type     context
  and char_t     = L.i8_type     context in
  let int_pt = L.pointer_type int_t
  and float_pt = L.pointer_type float_t
  and bool_pt = L.pointer_type bool_t
  and char_pt = L.pointer_type char_t in
  let char_ppt = L.pointer_type char_pt in
  let cobj_t = L.named_struct_type context "CObj" in
  let cobj_pt = L.pointer_type cobj_t in
  let cobj_ppt = L.pointer_type cobj_pt in
  let userdef_fn_t = L.function_type cobj_pt [| cobj_ppt |] in
  let userdef_fn_pt = L.pointer_type userdef_fn_t in
  let clist_t = L.named_struct_type context "CList" in
  let clist_pt = L.pointer_type clist_t in
  let cstring_t = L.named_struct_type context "CString" in
  let cstring_pt = L.pointer_type cstring_t in
  let ctype_t = L.named_struct_type context "CType" in
  let ctype_pt = L.pointer_type ctype_t in
  let ctype_ppt = L.pointer_type ctype_pt in
  let cobj_data_idx = 0
  and cobj_type_idx = 1 in
  let clist_data_idx = 0
  and clist_len_idx = 1
  and clist_cap_idx = 2 in
  let ctype_add_idx = 0
  and ctype_sub_idx = 1
  and ctype_mul_idx = 2
  and ctype_div_idx = 3
  and ctype_exp_idx = 4
  and ctype_mod_idx = 5 
  and ctype_eq_idx = 6
  and ctype_neq_idx = 7
  and ctype_lesser_idx = 8
  and ctype_leq_idx = 9
  and ctype_greater_idx = 10
  and ctype_geq_idx = 11
  and ctype_and_idx = 12
  and ctype_or_idx = 13
  and ctype_idx_idx = 14
  and ctype_idx_parent_idx = 15
  and ctype_neg_idx = 16
  and ctype_not_idx = 17
  and ctype_heapify_idx = 18
  and ctype_print_idx = 19
  and ctype_call_idx = 20
  and num_ctype_idxs = 21 in
  let ctype_add_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_sub_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_mul_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_div_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_mod_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_exp_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_eq_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_neq_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_lesser_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_leq_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_greater_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_geq_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_and_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_or_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_idx_t = L.function_type cobj_pt [| cobj_pt; cobj_pt |]
  and ctype_idx_parent_t = L.function_type (L.pointer_type cobj_pt) [| cobj_pt; cobj_pt |]
  and ctype_neg_t = L.function_type cobj_pt [| cobj_pt |]
  and ctype_not_t = L.function_type cobj_pt [| cobj_pt |]
  and ctype_heapify_t = L.function_type int_t [| cobj_pt |]
  and ctype_print_t = L.function_type int_t [| cobj_pt |]
  and ctype_call_t = L.function_type cobj_pt [| cobj_pt ; cobj_ppt |] in
  let ctype_add_pt = L.pointer_type ctype_add_t
  and ctype_sub_pt = L.pointer_type ctype_sub_t
  and ctype_mul_pt = L.pointer_type ctype_mul_t
  and ctype_div_pt = L.pointer_type ctype_div_t
  and ctype_mod_pt = L.pointer_type ctype_mod_t
  and ctype_exp_pt = L.pointer_type ctype_exp_t
  and ctype_eq_pt = L.pointer_type ctype_eq_t
  and ctype_neq_pt = L.pointer_type ctype_neq_t
  and ctype_lesser_pt = L.pointer_type ctype_lesser_t
  and ctype_leq_pt = L.pointer_type ctype_leq_t
  and ctype_greater_pt = L.pointer_type ctype_greater_t
  and ctype_geq_pt = L.pointer_type ctype_geq_t
  and ctype_and_pt = L.pointer_type ctype_and_t
  and ctype_or_pt = L.pointer_type ctype_or_t
  and ctype_idx_pt = L.pointer_type ctype_idx_t
  and ctype_idx_parent_pt = L.pointer_type ctype_idx_parent_t
  and ctype_neg_pt = L.pointer_type ctype_neg_t
  and ctype_not_pt = L.pointer_type ctype_not_t
  and ctype_heapify_pt = L.pointer_type ctype_heapify_t
  and ctype_print_pt = L.pointer_type ctype_print_t
  and ctype_call_pt = L.pointer_type ctype_call_t in
  let ctype_t = L.named_struct_type context "CType" in
  let ctype_pt = L.pointer_type ctype_t in
  ignore(L.struct_set_body cobj_t [| char_pt; ctype_pt |] false);
  ignore(L.struct_set_body clist_t [| char_pt; int_t; int_t |] false);
  ignore(L.struct_set_body cstring_t [| char_pt; int_t; int_t |] false);
  ignore(L.struct_set_body ctype_t [|
  	ctype_add_pt;
  	ctype_sub_pt;
  	ctype_mul_pt;
  	ctype_mod_pt;
    ctype_div_pt;
    ctype_exp_pt;
    ctype_eq_pt;
    ctype_neq_pt;
    ctype_lesser_pt;
  	ctype_leq_pt;
  	ctype_greater_pt;
  	ctype_geq_pt;
  	ctype_and_pt;
  	ctype_or_pt;
  	ctype_idx_pt;
    ctype_idx_parent_pt;
  	ctype_neg_pt;
    ctype_not_pt;
    ctype_heapify_pt;
    ctype_print_pt;
    ctype_call_pt |] false);
   let get_t = function
     | "int" -> int_t
     | "float" -> float_t
     | "bool" -> bool_t
     | "char" -> char_t
     | "list" -> clist_t
     | "string" -> cstring_t
   in
   let printf_t : L.lltype =
     L.var_arg_function_type int_t [| char_pt |] in
   let printf_func : L.llvalue =
     L.declare_function "printf" printf_t the_module in
   let exit_t : L.lltype =
     L.function_type (int_t) [| int_t |] in
   let exit_func : L.llvalue =
     L.declare_function "exit" exit_t the_module in
   let pow_t : L.lltype =
     L.function_type (float_t) [| float_t; float_t |] in
   let pow_func : L.llvalue =
     L.declare_function "pow" pow_t the_module in
   let build_ctype_fn fname ftype =
     let the_function = L.define_function fname ftype the_module in
     let builder = L.builder_at_end context (L.entry_block the_function) in
     (the_function, builder)
   in
  let build_getdata_cobj data_type cobj_p b =
    let x2 = L.build_struct_gep cobj_p cobj_data_idx "x2" b in
    let x3 = L.build_load x2 "x3" b in 
    let x4 = L.build_bitcast x3 (L.pointer_type data_type) "x4" b in 
    let data = L.build_load x4 "data" b in 
    data
  in
  let build_gettype_cobj cobj_p b =
    let x2 = L.build_struct_gep cobj_p cobj_type_idx "x2" b in
    let x3 = L.build_load x2 "x3" b in
    let x4 = L.build_bitcast x3 (L.pointer_type ctype_t) "x4" b in
    x4
  in
  let build_getlist_cobj cobj_p b =
    let gep_addr = L.build_struct_gep cobj_p cobj_data_idx "__gep_addr" b in
    let objptr = L.build_load gep_addr "__objptr" b in
    L.build_bitcast objptr clist_pt "__clistptr" b
  in
  let build_getlen_clist clist_p b =
    let gep_addr = L.build_struct_gep clist_p clist_len_idx "__gep_addr" b in
    let gep_addr_as_intptr = L.build_bitcast gep_addr int_pt "__gep_addr_as_intptr" b in
    let length = L.build_load gep_addr_as_intptr "__length" b in
    length
  in
  let build_getcap_clist clist_p b =
    let gep_addr = L.build_struct_gep clist_p clist_cap_idx "__gep_addr" b in 
    let gep_addr_as_intptr = L.build_bitcast gep_addr int_pt "__gep_addr_as_intptr" b in
    let capacity = L.build_load gep_addr_as_intptr "__capacity" b in
    capacity
  in
  let build_fnptr_of_cfo cobj_p b =
    let x2 = L.build_struct_gep cobj_p cobj_data_idx "x2" b in
    let x3 = L.build_load x2 "x3" b in
    let fnptr = L.build_bitcast x3 userdef_fn_pt "fnptr" b in
    fnptr
  in
  let build_getctypefn_cobj ctype_fn_idx cobj_p b =
    let x2 = L.build_struct_gep cobj_p cobj_type_idx "x2" b in
    let x3 = L.build_load x2 "x3" b in
    let x4 = L.build_struct_gep x3 ctype_fn_idx "x4" b in
    let fn_ptr = L.build_load x4 "fn_ptr" b in
    fn_ptr
  in
  let build_new_cobj_empty builder =
    let objptr = L.build_malloc cobj_t "__new_objptr" builder in
    let datafieldptr = L.build_struct_gep objptr cobj_data_idx "datafieldptr" builder in
    let ctypefieldptr = L.build_struct_gep objptr cobj_type_idx "ctypefieldptr" builder in
    (objptr, datafieldptr, ctypefieldptr)
  in
  let build_new_clist dataptr_of_cobj elm_pts builder =
    let length = List.length elm_pts in
    let len = L.const_int int_t length in
    let capacity = length in
    let cap = L.const_int int_t capacity in
    let dataptr = L.build_malloc (L.array_type cobj_pt capacity) "__new_dataptr" builder in
    let dataptr_as_i8ptr = L.build_bitcast dataptr char_pt "dataptr_as_i8" builder in
    let elm_pts_as_cobjptrs = List.map (fun e ->
      let elm_pt_as_cobjptr = L.build_bitcast e cobj_pt "elm_ptr_as_cobjptr" builder
      in elm_pt_as_cobjptr) elm_pts in
    let elms_w_nulls = if List.length elm_pts_as_cobjptrs < capacity
      then elm_pts_as_cobjptrs @ (Array.to_list (Array.make (capacity - List.length elm_pts) (L.const_pointer_null cobj_pt)))
      else elm_pts_as_cobjptrs in
    let store_elms elm idx =
      let gep_addr = L.build_gep dataptr [|L.const_int int_t 0; L.const_int int_t idx|] "__elem_ptr" builder in
      ignore(L.build_store elm gep_addr builder); ()
    in
    ignore(List.iter2 store_elms elms_w_nulls (seq capacity));
    let datafieldptr = L.build_struct_gep dataptr_of_cobj clist_data_idx "datafieldptr" builder in
    let datafieldptr_as_i8ptrptr = L.build_bitcast datafieldptr (L.pointer_type char_pt) "datafieldptr_as_i8ptrptr" builder in
    ignore(L.build_store dataptr_as_i8ptr datafieldptr_as_i8ptrptr builder);
    let lenfieldptr = L.build_struct_gep dataptr_of_cobj clist_len_idx "lenfieldptr" builder in
    ignore(L.build_store len lenfieldptr builder);
    let capfieldptr = L.build_struct_gep dataptr_of_cobj clist_cap_idx "capfieldptr" builder in
    ignore(L.build_store cap capfieldptr builder);
  in
  let build_new_clist_init dataptr_of_cobj listptr_as_i8ptr length builder =
    let len = length in
    let cap = length in
    let datafieldptr = L.build_struct_gep dataptr_of_cobj clist_data_idx "datafieldptr" builder in
    let datafieldptr_as_i8ptrptr = L.build_bitcast datafieldptr (L.pointer_type char_pt) "datafieldptr_as_i8ptrptr" builder in
    ignore(L.build_store listptr_as_i8ptr datafieldptr_as_i8ptrptr builder);
    let lenfieldptr = L.build_struct_gep dataptr_of_cobj clist_len_idx "lenfieldptr" builder in
    ignore(L.build_store len lenfieldptr builder);
    let capfieldptr = L.build_struct_gep dataptr_of_cobj clist_cap_idx "capfieldptr" builder in
    ignore(L.build_store cap capfieldptr builder);
  in
  let boilerplate_till_load remote_cobj_p prettyname b =
    ignore(L.set_value_name ("remote_" ^ prettyname) remote_cobj_p);
    let cobj_pp = L.build_alloca cobj_pt (prettyname ^ "_p") b in
    ignore(L.build_store remote_cobj_p cobj_pp b);
    let cobj_p = L.build_load cobj_pp (prettyname ^ "_p") b in
    cobj_p
  in
  let boilerplate_binop data_type fn b =
    let formals_llvalues = (Array.to_list (L.params fn)) in
    let [ remote_self_p; remote_other_p ] = formals_llvalues in
    let self_p = boilerplate_till_load remote_self_p "self_p" b in
    let other_p = boilerplate_till_load remote_other_p "other_p" b in
    let self_data = build_getdata_cobj data_type self_p b in
    let other_data = build_getdata_cobj data_type other_p b in
    (self_data, other_data)
  in
  let boilerplate_uop data_type fn b =
    let formals_llvalues = (Array.to_list (L.params fn)) in
    let [ remote_self_p ] = formals_llvalues in
    let self_p = boilerplate_till_load remote_self_p "self_p" b in
    let self_data = build_getdata_cobj data_type self_p b in
    (self_data)
  in
  let boilerplate_lop fn b =
    let formals_llvalues = (Array.to_list (L.params fn)) in
    let [ remote_self_p; remote_other_p ] = formals_llvalues in
    let self_p = boilerplate_till_load remote_self_p "self_p" b in
    let other_p = boilerplate_till_load remote_other_p "other_p" b in
    let self_data = build_getlist_cobj self_p b in
    let other_data = build_getlist_cobj other_p b in
    (self_data, other_data)
  in
  let boilerplate_idxop fn b =
    let formals_llvalues = Array.to_list (L.params fn) in
    let [ remote_self_p; remote_other_p ] = formals_llvalues in
    let self_p = boilerplate_till_load remote_self_p "self_p" b in
    let other_p = boilerplate_till_load remote_other_p "other_p" b in
    let self_data = build_getlist_cobj self_p b in
    let other_data = build_getdata_cobj int_t other_p b in
    (self_data, other_data)
  in
  let build_pow self_p other_p name b =
    let self_as_float = L.build_sitofp self_p float_t "self_as_float" b in
    let other_as_float = L.build_sitofp other_p float_t "other_as_float" b in
    let result = L.build_call pow_func [| self_as_float; other_as_float |] "pow" b in
    let result_as_int = L.build_fptosi result int_t "result_as_int" b in
    result_as_int
  in
  let build_fpow self_p other_p name b =
    let result = L.build_call pow_func [| self_p ; other_p |] "pow" b in
    result
  in
  let build_idx self_p other_p name b =
     let gep_addr = L.build_struct_gep self_p clist_data_idx "__gep_addr" b in
     let gep_addr_as_cobjptrptrptr = L.build_bitcast gep_addr (L.pointer_type (L.pointer_type cobj_pt)) "__gep_addr_as_cobjptrptrptr" b in
     let gep_addr_as_cobjptrptr = L.build_load gep_addr_as_cobjptrptrptr "__gep_addr_as_cobjptrptr" b in
     let gep_addr_as_cobjptrptr = L.build_gep gep_addr_as_cobjptrptr [| other_p |] "__gep_addr_as_cobjptrptr" b in
     let cobjptr = L.build_load gep_addr_as_cobjptrptr "__cobjptr" b in
     cobjptr
  in
  let build_idx_parent self_p other_p name b =
   let gep_addr = L.build_struct_gep self_p clist_data_idx "__gep_addr" b in
   let gep_addr_as_cobjptrptrptr = L.build_bitcast gep_addr (L.pointer_type (L.pointer_type cobj_pt)) "__gep_addr_as_cobjptrptrptr" b in
   let gep_addr_as_cobjptrptr = L.build_load gep_addr_as_cobjptrptrptr "__gep_addr_as_cobjptrptr" b in
   let parent = L.build_gep gep_addr_as_cobjptrptr [| other_p |] "__gep_addr_as_cobjptrptr" b in
   parent
  in
  let build_iheapify self_p name b =
    let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
    let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type int_t)) "dat" b in
    let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
    let rawdata = L.build_load rawdata_addr "raw_data" b in
    let heap_data_p = L.build_malloc int_t "heap_data_p" b in
    ignore(L.build_store rawdata heap_data_p b);
    let heap_data_p = L.build_bitcast heap_data_p char_pt "heap_data_p" b in
    ignore(L.build_store heap_data_p dataptr_addr_i8pp b);
    L.build_ret (L.const_int int_t 0) b
  in
  let build_fheapify self_p name b =
    let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
    let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type float_t)) "dat" b in
    let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
    let rawdata = L.build_load rawdata_addr "raw_data" b in
    let heap_data_p = L.build_malloc float_t "heap_data_p" b in
    ignore(L.build_store rawdata heap_data_p b);
    let heap_data_p = L.build_bitcast heap_data_p char_pt "heap_data_p" b in
    ignore(L.build_store heap_data_p dataptr_addr_i8pp b);
    L.build_ret (L.const_int int_t 0) b
  in
  let build_bheapify self_p name b =
    let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
    let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type bool_t)) "dat" b in
    let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
    let rawdata = L.build_load rawdata_addr "raw_data" b in
    let heap_data_p = L.build_malloc bool_t "heap_data_p" b in
    ignore(L.build_store rawdata heap_data_p b);
    let heap_data_p = L.build_bitcast heap_data_p char_pt "heap_data_p" b in
    ignore(L.build_store heap_data_p dataptr_addr_i8pp b);
    L.build_ret (L.const_int int_t 0) b
  in
  let build_lheapify self_p name b =
    L.build_ret (L.const_int int_t 0) b
  in
  let build_sheapify self_p name b =
    L.build_ret (L.const_int int_t 0) b
  in
  let build_fcheapify self_p name b =
    L.build_ret (L.const_int int_t 0) b
  in
  let build_iprint self_p name b =
      let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
      let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type int_t)) "dat" b in
      let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
      let rawdata = L.build_load rawdata_addr "raw_data" b in
      let format_str = L.build_global_stringptr "%d" "fmt" b in
      ignore(L.build_call printf_func [| format_str ; rawdata |] "printf" b);
      L.build_ret (L.const_int int_t 0) b
  in
  let build_fprint self_p name b =
      let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
      let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type float_t)) "dat" b in
      let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
      let rawdata = L.build_load rawdata_addr "raw_data" b in
      let format_str = L.build_global_stringptr "%g" "fmt" b in
      ignore(L.build_call printf_func [| format_str ; rawdata |] "printf" b);
      L.build_ret (L.const_int int_t 0) b
  in
  let build_bprint self_p name b =
      let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
      let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type bool_t)) "dat" b in
      let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
      let rawdata = L.build_load rawdata_addr "raw_data" b in
      let format_str = L.build_global_stringptr "%d" "fmt" b in
      ignore(L.build_call printf_func [| format_str ; rawdata |] "printf" b);
      L.build_ret (L.const_int int_t 0) b
  in
  let build_cprint self_p name b =
      let dataptr_addr_i8pp = L.build_struct_gep self_p cobj_data_idx "dat" b in
      let dataptr_addr = L.build_bitcast dataptr_addr_i8pp (L.pointer_type (L.pointer_type bool_t)) "dat" b in
      let rawdata_addr = L.build_load dataptr_addr "raw_data_addr" b in
      let rawdata = L.build_load rawdata_addr "raw_data" b in
      let format_str = L.build_global_stringptr "%c" "fmt" b in
      ignore(L.build_call printf_func [| format_str ; rawdata |] "printf" b);
      L.build_ret (L.const_int int_t 0) b
  in
  let build_lprint self_p name b =
    let listptr = build_getlist_cobj self_p b in
    let nptr = L.build_alloca int_t "nptr" b in
    ignore(L.build_store (L.const_int int_t (0)) nptr b);
    let n = L.build_load nptr "n" b in
    let ln = build_getlen_clist listptr b in
    let fs1 = L.build_global_stringptr "[" "fmt" b in
    let fs2 = L.build_global_stringptr ", " "fmt" b in
    let fs3 = L.build_global_stringptr "]" "fmt" b in
    ignore(L.build_call printf_func [| fs1 ; L.const_int int_t 0 |] "printf" b);
    let iter_bb = L.append_block context "iter" (L.block_parent (L.insertion_block b)) in
    ignore(L.build_br iter_bb b);
    let iter_builder = L.builder_at_end context iter_bb in
    let n = L.build_load nptr "n" iter_builder in
    let nnext = L.build_add n (L.const_int int_t 1) "nnext" iter_builder in
    ignore(L.build_store nnext nptr iter_builder);
    let iter_complete = (L.build_icmp L.Icmp.Sge) n ln "iter_complete" iter_builder in
    let body_bb = L.append_block context "list_print_body" (L.block_parent (L.insertion_block b))  in
    let body_builder = L.builder_at_end context body_bb in
    let elmptr = build_idx listptr n "list_index_result" body_builder in
    let fn_p = build_getctypefn_cobj ctype_print_idx elmptr body_builder in
    ignore(L.build_call fn_p [|elmptr|] "print_cob" body_builder);
    ignore(L.build_call printf_func [| fs2 ; L.const_int int_t 0 |] "printf" body_builder);
    ignore(L.build_br iter_bb body_builder);
    let merge_bb = L.append_block context "merge" (L.block_parent (L.insertion_block b))  in
    ignore(L.build_cond_br iter_complete merge_bb body_bb iter_builder);
    let end_builder = L.builder_at_end context merge_bb in
    ignore(L.build_call printf_func [| fs3 ; L.const_int int_t 0 |] "printf" end_builder);
    L.build_ret (L.const_int int_t 0) end_builder
  in
  let build_sprint self_p name b =
    let listptr = build_getlist_cobj self_p b in
    let nptr = L.build_alloca int_t "nptr" b in
    ignore(L.build_store (L.const_int int_t (0)) nptr b);
    let n = L.build_load nptr "n" b in
    let ln = build_getlen_clist listptr b in
    let iter_bb = L.append_block context "iter" (L.block_parent (L.insertion_block b)) in
    ignore(L.build_br iter_bb b);
    let iter_builder = L.builder_at_end context iter_bb in
    let n = L.build_load nptr "n" iter_builder in
    let nnext = L.build_add n (L.const_int int_t 1) "nnext" iter_builder in
    ignore(L.build_store nnext nptr iter_builder);
    let iter_complete = (L.build_icmp L.Icmp.Sge) n ln "iter_complete" iter_builder in
    let body_bb = L.append_block context "list_print_body" (L.block_parent (L.insertion_block b)) in
    let body_builder = L.builder_at_end context body_bb in
    let elmptr = build_idx listptr n "list_index_result" body_builder in
    let fn_p = build_getctypefn_cobj ctype_print_idx elmptr body_builder in
    ignore(L.build_call fn_p [|elmptr|] "print_cob" body_builder);
    ignore(L.build_br iter_bb body_builder);
    let merge_bb = L.append_block context "merge" (L.block_parent (L.insertion_block b)) in
    ignore(L.build_cond_br iter_complete merge_bb body_bb iter_builder);
    let end_builder = L.builder_at_end context merge_bb in
    L.build_ret (L.const_int int_t 0) end_builder
  in
  let built_ops =
  	 let typs = ["int"; "float"; "bool"; "char"; "list"; "string"; "func"] in
  	 let ops = [
  	   Oprt("add", Some((L.build_add), int_t), Some((L.build_fadd), float_t), None, None, Some((L.build_add), clist_t), Some((L.build_add), cstring_t), None);
       Oprt("sub", Some((L.build_sub), int_t), Some((L.build_fsub), float_t), None, None, None, None, None);
       Oprt("mul", Some((L.build_mul), int_t), Some((L.build_fmul), float_t), None, None, None, None, None);
       Oprt("mod", Some((L.build_srem), int_t), Some((L.build_frem), float_t), None, None, None, None, None);
       Oprt("div", Some((L.build_sdiv), int_t), Some((L.build_fdiv), float_t), None, None, None, None, None);
       Oprt("exp", Some((build_pow), int_t), Some((build_fpow), float_t), None, None, None, None, None);
       Oprt("eq", Some((L.build_icmp L.Icmp.Eq), bool_t), Some((L.build_fcmp L.Fcmp.Ueq), bool_t), Some((L.build_icmp L.Icmp.Eq), bool_t), Some((L.build_icmp L.Icmp.Eq), bool_t), None, None, None);
       Oprt("neq", Some((L.build_icmp L.Icmp.Ne), bool_t), Some((L.build_fcmp L.Fcmp.Une), bool_t), Some((L.build_icmp L.Icmp.Eq), bool_t), Some((L.build_icmp L.Icmp.Eq), bool_t), None, None, None);
       Oprt("lesser", Some((L.build_icmp L.Icmp.Slt), bool_t), Some((L.build_fcmp L.Fcmp.Ult), bool_t), Some((L.build_icmp L.Icmp.Slt), bool_t), Some((L.build_icmp L.Icmp.Slt), bool_t), None, None, None);
       Oprt("leq", Some((L.build_icmp L.Icmp.Sle), bool_t), Some((L.build_fcmp L.Fcmp.Ule), bool_t), Some((L.build_icmp L.Icmp.Sle), bool_t), Some((L.build_icmp L.Icmp.Sle), bool_t), None, None, None);
       Oprt("greater", Some((L.build_icmp L.Icmp.Sgt), bool_t), Some((L.build_fcmp L.Fcmp.Ugt), bool_t), Some((L.build_icmp L.Icmp.Sgt), bool_t), Some((L.build_icmp L.Icmp.Sgt), bool_t), None, None, None);
       Oprt("geq", Some((L.build_icmp L.Icmp.Sge), bool_t), Some((L.build_fcmp L.Fcmp.Uge), bool_t), Some((L.build_icmp L.Icmp.Sge), bool_t), Some((L.build_icmp L.Icmp.Sge), bool_t), None, None, None);
       Oprt("and", Some((L.build_and), int_t), None, Some((L.build_and), bool_t), Some((L.build_add), char_t), None, None, None);
       Oprt("or", Some((L.build_or), int_t), None, Some((L.build_or), bool_t), Some((L.build_or), char_t), None, None, None);
       Oprt("idx", None, None, None, None, Some((build_idx), int_t), Some((build_idx), int_t), None);
       Oprt("idx_parent", None, None, None, None, Some((build_idx_parent), int_t), None, None);
       Uoprt("neg", Some((L.build_neg), int_t), Some((L.build_fneg), float_t), Some((L.build_neg), bool_t), None, None, None, None);
       Uoprt("not", Some((L.build_not), int_t), None, Some((L.build_not), bool_t), Some((L.build_not), char_t), None, None, None);
       Uoprt("heapify", Some((build_iheapify), int_t), Some((build_fheapify), int_t), Some((build_bheapify), int_t), None, Some((build_lheapify), int_t), Some((build_sheapify), int_t), Some((build_fcheapify), int_t));
       Uoprt("print", Some((build_iprint), int_t), Some((build_fprint), int_t), Some((build_bprint), int_t), Some((build_cprint), int_t), Some((build_lprint), int_t), Some((build_sprint), int_t), None);
       Coprt("call", None, None, None, None, None, None, Some((L.build_call), int_t));
       ] in
  	 List.map (fun t -> let bops = List.map (function
  	    | Oprt(o, i, f, b, c, l, s, fc) ->
          let tfn = match t with
            | "int" -> i
            | "float" -> f
            | "bool" -> b
            | "char" -> c
            | "list" -> l
            | "string" -> s
            | "func" -> fc
		      in
		      let bop = match tfn with
			      | Some tfn ->
			        let (fn, bd) = build_ctype_fn (t ^ "_" ^ o) ((function
			          | "add" -> ctype_add_t
                | "sub" -> ctype_sub_t
                | "mul" -> ctype_mul_t
                | "div" -> ctype_div_t
                | "mod" -> ctype_mod_t
                | "exp" -> ctype_exp_t
                | "eq" -> ctype_eq_t
                | "neq" -> ctype_neq_t
                | "lesser" -> ctype_lesser_t
                | "leq" -> ctype_leq_t
                | "greater" -> ctype_greater_t
                | "geq" -> ctype_geq_t
                | "and" -> ctype_and_t
                | "or" -> ctype_or_t
                | "idx" -> ctype_idx_t
                | "idx_parent" -> ctype_idx_parent_t) o)
				      in BOprt(o, Some(((fn, bd), tfn)))
			      | None -> BOprt(o, None)
          in bop
        | Uoprt(o, i, f, b, c, l, s, fc) ->
          let tfn = match t with
            | "int" -> i
            | "float" -> f
            | "bool" -> b
            | "char" -> c
            | "list" -> l
            | "string" -> s
            | "func" -> fc
          in
		      let bop = match tfn with
			      | Some tfn ->
			        let (fn, bd) = build_ctype_fn (t ^ "_" ^ o) ((function
                | "neg" -> ctype_neg_t
                | "not" -> ctype_not_t
                | "heapify" -> ctype_heapify_t
                | "print" -> ctype_print_t) o)
				      in BUoprt(o, Some(((fn, bd), tfn)))
			      | None -> BUoprt(o, None)
		      in bop
        | Coprt(o, i, f, b, c, l, s, fc) ->
          let tfn = match t with
            | "int" -> i
            | "float" -> f
            | "bool" -> b
            | "char" -> c
            | "list" -> l
            | "string" -> s
            | "func" -> fc
          in
		      let bop = match tfn with
			      | Some tfn ->
			        let (fn, bd) = build_ctype_fn (t ^ "_" ^ o) ((function
                | "call" -> ctype_call_t) o)
				      in BCoprt(o, Some(((fn, bd), tfn)))
			      | None -> BCoprt(o, None)
		      in bop) ops
        in (t, bops)) typs
      in
  let [ctype_int; ctype_float; ctype_bool; ctype_char; ctype_list; ctype_string; ctype_func] =
  	List.map (fun (t, bops) -> L.define_global ("ctype_" ^ t) (L.const_named_struct ctype_t (Array.of_list (List.map (function
  	  | BOprt(fn, o) -> (match o with
  	    | Some(((fn, bd), tfn)) -> fn
  	    | None -> (match fn with
          | "idx" -> L.const_pointer_null ctype_idx_pt
          | "idx_parent" -> L.const_pointer_null ctype_idx_parent_pt
          | _ ->  L.const_pointer_null ctype_add_pt))
      | BUoprt(fn, o) -> (match o with
        | Some(((fn, bd), tfn)) -> fn
        | None -> (match fn with
          | "heapify" -> L.const_pointer_null ctype_heapify_pt
          | "print" -> L.const_pointer_null ctype_print_pt
          | _ -> L.const_pointer_null ctype_neg_pt))
  	  | BCoprt(fn, o) -> (match o with
  	    | Some(((fn, bd), tfn)) -> fn
  	    | None -> (match fn with
          | _ -> L.const_pointer_null ctype_call_pt))) bops))) the_module) built_ops in
  let ctype_of_ASTtype = function
    | Int -> Some ctype_int
    | Float -> Some ctype_float
    | Bool -> Some ctype_bool
    | String -> Some ctype_string
    | Dyn -> None
    | FuncType -> Some ctype_func
    | Arr -> Some ctype_list
    | Null -> None
  in
  let ctype_of_datatype = function
    | dt when dt = int_t -> ctype_int
    | dt when dt = float_t -> ctype_float
    | dt when dt = bool_t -> ctype_bool
    | dt when dt = char_t -> ctype_char
    | dt when dt = clist_t -> ctype_list
    | dt when dt = cstring_t -> ctype_string
  in
  let ctype_of_typ = function
      | Int -> ctype_int
      | Float -> ctype_float
      | Bool -> ctype_bool
      | Dyn -> ctype_int
  in
  let build_new_cobj data_type builder =
    let objptr = L.build_malloc cobj_t "__new_objptr" builder in
    let dataptr = L.build_malloc data_type "__new_dataptr" builder in
    let dataptr_as_i8ptr = L.build_bitcast dataptr char_pt "dataptr_as_i8" builder in
    let ctypefieldptr = L.build_struct_gep objptr cobj_type_idx "ctypefieldptr" builder in
    ignore(L.build_store (ctype_of_datatype data_type) ctypefieldptr builder);
    let datafieldptr = L.build_struct_gep objptr cobj_data_idx "datafieldptr" builder in
    let datafieldptr_as_i8ptrptr = L.build_bitcast datafieldptr (L.pointer_type char_pt) "datafieldptr_as_i8ptrptr" builder in
    ignore(L.build_store dataptr_as_i8ptr datafieldptr_as_i8ptrptr builder);
    (objptr, dataptr)
  in
  let build_new_cobj_init data_type value b =
      let (objptr, dataptr) = build_new_cobj data_type b in
      ignore(L.build_store value dataptr b);
      objptr
  in
  let add_lists self_data other_data b =
    let self_ln = build_getlen_clist self_data b in
    let other_ln = build_getlen_clist other_data b in
    let total = L.build_add self_ln other_ln "total_length" b in
    let dataptr = L.build_array_malloc cobj_pt total "__new_dataptr" b in
    let dataptr_as_i8ptr = L.build_bitcast dataptr char_pt "dataptr_as_i8" b in
    let load_list listptr dataptr size fn b =
      let nptr = L.build_alloca int_t "nptr" b in
      ignore(L.build_store (L.const_int int_t 0) nptr b);
      let iter_bb = L.append_block context "iter" fn in
      ignore(L.build_br iter_bb b);
      let iter_builder = L.builder_at_end context iter_bb in
      let n = L.build_load nptr "n" iter_builder in
      let nnext = L.build_add n (L.const_int int_t 1) "nnext" iter_builder in
      ignore(L.build_store nnext nptr iter_builder);
      let iter_complete = (L.build_icmp L.Icmp.Sge) n size "iter_complete" iter_builder in
      let body_bb = L.append_block context "list_add_body" fn in
      let body_builder = L.builder_at_end context body_bb in
      let elmptr = build_idx listptr n "list_index_result" body_builder in
      let gep_addr = L.build_gep dataptr [|n|] "__elem_ptr" body_builder in
      ignore(L.build_store elmptr gep_addr body_builder);
      ignore(L.build_br iter_bb body_builder);
      let merge_bb = L.append_block context "merge" fn in
      ignore(L.build_cond_br iter_complete merge_bb body_bb iter_builder);
      let end_builder = L.builder_at_end context merge_bb in
      end_builder
    in
    let builder1 = load_list self_data dataptr self_ln (L.block_parent (L.insertion_block b)) b in
    let dataptr1 = L.build_gep dataptr [|self_ln|] "__next_dataptr" builder1 in
    let builder2 = load_list other_data dataptr1 other_ln (L.block_parent (L.insertion_block b)) builder1 in
    (builder2, dataptr_as_i8ptr, total)
  in
  let build_ladd self_p other_p name b =
    let (builder, dataptr_as_i8ptr, total) = add_lists self_p other_p b in
    let (newobjptr, newdataptr) = build_new_cobj clist_t builder in
    let _ = build_new_clist_init newdataptr dataptr_as_i8ptr total builder in
    (builder, newobjptr)
  in
  let build_sadd self_p other_p name b =
    let (builder, dataptr_as_i8ptr, total) = add_lists self_p other_p b in
    let (newobjptr, newdataptr) = build_new_cobj cstring_t builder in
    let _ = build_new_clist_init newdataptr dataptr_as_i8ptr total builder in
    (builder, newobjptr)
  in
  let build_string_idx self_p other_p name b =
     let gep_addr = L.build_struct_gep self_p clist_data_idx "__gep_addr" b in
     let gep_addr_as_cobjptrptrptr = L.build_bitcast gep_addr (L.pointer_type (L.pointer_type cobj_pt)) "__gep_addr_as_cobjptrptrptr" b in
     let gep_addr_as_cobjptrptr = L.build_load gep_addr_as_cobjptrptrptr "__gep_addr_as_cobjptrptr" b in
     let gep_addr_as_cobjptrptr = L.build_gep gep_addr_as_cobjptrptr [| other_p |] "__gep_addr_as_cobjptrptr" b in
     let cobjptr = L.build_load gep_addr_as_cobjptrptr "__cobjptr" b in
     let (objptr, dataptr) = build_new_cobj cstring_t b in 
     let _ = build_new_clist dataptr [cobjptr] b in
     objptr
  in
  List.iter (fun (t, bops) -> List.iter (function
    | BOprt(fn, o) -> (match fn with
      | "idx" -> (match t with
        | "string" -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_idxop fn bd in
            let result_data = build_string_idx self_data other_data "result_data" bd in
            let result = result_data in
            ignore(L.build_ret result bd)
          | None -> ())
        | _ -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_idxop fn bd in
            let result_data = tf self_data other_data "result_data" bd in
            let result = result_data in
            ignore(L.build_ret result bd)
          | None -> ())
        )

      | "idx_parent" -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_idxop fn bd in
            let result_data = tf self_data other_data "result_data" bd in
            let result = result_data in
            ignore(L.build_ret result bd)
          | None -> ())

      | "add" -> (match t with
        | "list" -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_lop fn bd in
            let (newbuilder, result_data) = build_ladd self_data other_data "result_data" bd in
            let result = result_data in
            ignore(L.build_ret result newbuilder)
          | None -> ())
        | "string" -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_lop fn bd in
            let (newbuilder, result_data) = build_sadd self_data other_data "result_data" bd in
            let result = result_data in
            ignore(L.build_ret result newbuilder)
          | None -> ())
        | _ -> (match o with
          | Some(((fn, bd), tfn)) ->
            let (tf, tp) = tfn in
            let (self_data, other_data) = boilerplate_binop (get_t t) fn bd in
            let result_data = tf self_data other_data "result_data" bd in
            let result = build_new_cobj_init tp result_data bd in
            ignore(L.build_ret result bd)
          | None -> ()))
      | _ -> (match o with
        | Some(((fn, bd), tfn)) ->
          let (tf, tp) = tfn in
          let (self_data, other_data) = boilerplate_binop (get_t t) fn bd in
          let result_data = tf self_data other_data "result_data" bd in
          let result = build_new_cobj_init tp result_data bd in
          ignore(L.build_ret result bd)
        | None -> ()))
    | BUoprt(fn, o) -> (match fn with
      | "heapify" | "print" -> (match o with
        | Some(((fn, bd), tfn)) ->
          let (tf, tp) = tfn in
          let formals_llvalues = (Array.to_list (L.params fn)) in
          let [remote_self_p] = formals_llvalues in
          let objptr = boilerplate_till_load remote_self_p "self_p" bd in
          ignore(tf objptr "result_data" bd)
        | None -> ())
      | _ -> (match o with
        | Some(((fn, bd), tfn)) ->
          let (tf, tp) = tfn in
          let (self_data) = boilerplate_uop (get_t t) fn bd in
          let result_data = tf self_data "result_data" bd in
          let result = build_new_cobj_init tp result_data bd in
          ignore(L.build_ret result bd)
        | None -> ()))
    | BCoprt(fn, o) -> (match o with
      | Some(((fn, bd), tfn)) ->
        let (tf, tp) = tfn in
        let formals_llvalues = (Array.to_list (L.params fn)) in
        let [ remote_self_p ; remote_argv ] = formals_llvalues in
        let self_p = boilerplate_till_load remote_self_p "self_p" bd in
        ignore(L.set_value_name ("remote_argv") remote_argv);
        let argv_p = L.build_alloca cobj_ppt "argv_p" bd in
        ignore(L.build_store remote_argv argv_p bd);
        let argv = L.build_load argv_p "argv" bd in
        let fn_p = build_fnptr_of_cfo self_p bd in
        let result = tf fn_p [|argv|] "result" bd in
        ignore(L.build_ret result bd)
      | None -> ())) bops) built_ops;
  let name_of_bind = function
      | Bind(name,_) -> name
  in
  let type_of_bind = function
      | Bind(_,ty) -> ty
  in
  let ltyp_of_typ = function
      | Int -> int_t
      | Float -> float_t
      | Bool -> bool_t
      | _ -> cobj_pt
  in
  let const_of_typ = function
      | Int -> L.const_null int_t
      | Float -> L.const_null float_t
      | Bool -> L.const_null bool_t
      | String -> L.const_null cobj_pt
      | FuncType -> L.const_null cobj_pt
      | Dyn -> L.const_null cobj_pt
      | Arr -> L.const_null cobj_pt
      | _ -> raise (Failure "CodegenError: unexpected type encountered in const_of_typ")
  in
  let names_of_bindlist bindlist =
    List.map name_of_bind bindlist
  in
  let build_binding_list local_builder_opt binds dynify_all =
      let dynify bind =
         let Bind(name,_) = bind in
           Bind(name, Dyn)
      in
      let dyns_list =
          List.map dynify binds
      in
      let binds = if dynify_all then List.sort_uniq Pervasives.compare (binds @ dyns_list) else binds
      in
      let prettyname_of_bind bind = (name_of_bind bind) ^ "_" ^ (string_of_typ (type_of_bind bind))
      in
      let get_const bind = match (type_of_bind bind) with 
        | Int -> L.const_null int_t
        | Float -> L.const_null float_t
        | Bool -> L.const_null bool_t
        | _ -> L.define_global ((prettyname_of_bind bind) ^ "_obj") (L.const_named_struct cobj_t [|L.const_pointer_null char_pt; L.const_pointer_null ctype_pt|]) the_module
      in
      let allocate bind = 
        let alloc_result = 
          (match local_builder_opt with
            | None -> L.define_global (prettyname_of_bind bind) (get_const bind) the_module
            | Some(builder) -> match type_of_bind bind with
              | Dyn -> 
                  let addr = L.build_alloca (ltyp_of_typ (type_of_bind bind)) (prettyname_of_bind bind) builder in 
                  let cobj_addr = L.build_malloc cobj_t "__new_objptr" builder in
                  ignore(L.build_store cobj_addr addr builder);
                  let cobj = L.const_named_struct cobj_t [|L.const_pointer_null char_pt; L.const_pointer_null ctype_pt|] in
                  ignore(L.build_store cobj cobj_addr builder); addr
              | _ -> L.build_alloca (ltyp_of_typ (type_of_bind bind)) (prettyname_of_bind bind) builder
          )
        in
        let (res, newbind) = match (type_of_bind bind) with
          | Int | Float | Bool -> (RawAddr(alloc_result), bind)
          | String -> (BoxAddr(alloc_result, false), Bind((name_of_bind bind), String))
          | Arr -> (BoxAddr(alloc_result, false), Bind((name_of_bind bind), Arr))
          | FuncType -> (BoxAddr(alloc_result, false), Bind((name_of_bind bind), FuncType))
          | _ -> (BoxAddr(alloc_result, false), Bind((name_of_bind bind), Dyn))
        in (res, newbind)
      in
        List.fold_left (fun map bind -> 
            let (res,newbind) = allocate bind in 
          BindMap.add newbind res map) BindMap.empty binds
  in
  let globals_map =
      let globals_list = snd prgm in
        build_binding_list None globals_list false
  in
  let lookup_global_binding bind = 
    try BindMap.find bind globals_map
    with Not_found -> BindMap.find bind globals_map
  in
  let main_ftype = L.function_type int_t [||] in
  let main_function = L.define_function "main" main_ftype the_module in
  let main_builder = L.builder_at_end context (L.entry_block main_function) in
  let int_format_str = L.build_global_stringptr "%d\n" "fmt" main_builder
  and string_format_str = L.build_global_stringptr "%s\n" "fmt" main_builder
  and float_format_str = L.build_global_stringptr "%g\n" "fmt" main_builder
  and newline_format_str = L.build_global_stringptr "\n" "fmt" main_builder in
  let init_state:state = {ret_typ=Int;namespace=BindMap.empty; func=main_function; b=main_builder;optim_funcs=SfdeclMap.empty;generic_func=false} in
  let seq len =
    let rec aux len acc =
      if len<0 then acc else aux (len-1) (len::acc)
    in aux (len-1) []
  in
  let lookup namespace bind = 
      let bind = match bind with
        | Bind(n, Int)| Bind(n, Float)| Bind(n, Bool) | Bind(n, String) | Bind(n, FuncType) | Bind(n, Arr) -> bind
        | Bind(n, _) -> Bind(n, Dyn)
      in try BindMap.find bind namespace
        with Not_found -> lookup_global_binding bind
  in
  let build_temp_box rawval raw_ty b =
      if raw_ty = Dyn then raise (Failure "CodegenError: attempting to build temp box for dynamic object.")
      else 
      let raw_ltyp = (ltyp_of_typ raw_ty) in
      let box_ptr = L.build_malloc cobj_t "box" b in
      let heap_data_p = L.build_malloc raw_ltyp "heap_data_temp_box" b in
      ignore(L.build_store rawval heap_data_p b);
      let heap_data_p = L.build_bitcast heap_data_p char_pt "heap_data_p" b in
      let dataptr_addr = L.build_struct_gep box_ptr cobj_data_idx "dat" b in
      let typeptr_addr = L.build_struct_gep box_ptr cobj_type_idx "ty" b in
      let typeptr_addr = L.build_bitcast typeptr_addr (L.pointer_type ctype_pt) "ty" b in
      ignore(L.build_store heap_data_p dataptr_addr b);
      ignore(L.build_store (ctype_of_typ raw_ty) typeptr_addr b);
      Box(box_ptr)
  in
  let rec change_state old = function
      | S_rettyp(ret_typ) -> {ret_typ=ret_typ;namespace=old.namespace;func=old.func;b=old.b;optim_funcs=old.optim_funcs;generic_func=old.generic_func}
      | S_names(namespace) -> {ret_typ=old.ret_typ;namespace=namespace;func=old.func;b=old.b;optim_funcs=old.optim_funcs;generic_func=old.generic_func}
      | S_func(func) -> {ret_typ=old.ret_typ;namespace=old.namespace;func=func;b=old.b;optim_funcs=old.optim_funcs;generic_func=old.generic_func}
      | S_b(b) -> {ret_typ=old.ret_typ;namespace=old.namespace;func=old.func;b=b;optim_funcs=old.optim_funcs;generic_func=old.generic_func}
      | S_optimfuncs(optim_funcs) -> {ret_typ=old.ret_typ;namespace=old.namespace;func=old.func;b=old.b;optim_funcs=optim_funcs;generic_func=old.generic_func}
      | S_generic_func(boolval) -> {ret_typ=old.ret_typ;namespace=old.namespace;func=old.func;b=old.b;optim_funcs=old.optim_funcs;generic_func=boolval}
    | S_needs_reboxing(name,boolval) -> 
      let BoxAddr(addr,_) = lookup (old.namespace) (Bind(name,Dyn)) in
      let new_namespace = BindMap.add (Bind(name,Dyn)) (BoxAddr(addr,boolval)) old.namespace in
      change_state old (S_names(new_namespace))
    | S_list(updates) -> List.fold_left change_state old updates
  in
  let rebox_if_needed boxaddr name the_state =
    match boxaddr with 
      | BoxAddr(addr, true) -> 
        let cobj_p = L.build_load addr name the_state.b in
        let fn_p = build_getctypefn_cobj ctype_heapify_idx cobj_p the_state.b in
        ignore(L.build_call fn_p [|cobj_p|] "heapify_result" the_state.b);
        change_state the_state (S_needs_reboxing(name, false))
      | BoxAddr(_, false) -> the_state
    in
  let check_defined addr message the_state = 
    if not !exceptions then the_state else
    let bad_op_bb = L.append_block context "bad_defined" the_state.func in
    let bad_op_bd = L.builder_at_end context bad_op_bb in
    let proceed_bb = L.append_block context "proceed" the_state.func in
    let cobj_addr = L.build_load addr "load_ptr" the_state.b in
    let dataptr_addr = L.build_struct_gep cobj_addr cobj_data_idx "dat_p_p" the_state.b in
    let dataptr = L.build_load dataptr_addr "load_ptr2" the_state.b in
    let invalid_addr = L.build_is_null dataptr "invalid_defined" the_state.b in
      ignore(L.build_cond_br invalid_addr bad_op_bb proceed_bb the_state.b);
    let err_message =
      let info = message in
        L.build_global_string info "error message" bad_op_bd in
    let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_op_bd in
      ignore(L.build_call printf_func [| str_format_str1 ; err_message |] "printf" bad_op_bd);
      ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_op_bd);
    let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
          ignore(L.build_br proceed_bb bad_op_bd); the_state
  in
  let check_null pointer message the_state =
    if not !exceptions then the_state else
    let bad_op_bb = L.append_block context "bad_null" the_state.func in
    let bad_op_bd = L.builder_at_end context bad_op_bb in
    let proceed_bb = L.append_block context "proceed" the_state.func in
    let invalid_op = L.build_is_null pointer "invalid_null" the_state.b in
      ignore(L.build_cond_br invalid_op bad_op_bb proceed_bb the_state.b);
    let err_message =
      let info = message in
        L.build_global_string info "error message" bad_op_bd in
    let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_op_bd in
      ignore(L.build_call printf_func [| str_format_str1 ; err_message |] "printf" bad_op_bd);
      ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_op_bd);
    let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
      ignore(L.build_br proceed_bb bad_op_bd); the_state
  in 
  let check_same_type v1 v2 message the_state = 
    if not !exceptions then the_state else
    let bad_arg_bb = L.append_block context "bad_type" the_state.func in
    let bad_arg_bd = L.builder_at_end context bad_arg_bb in
    let proceed_bb = L.append_block context "proceed" the_state.func in
    let typ1 = build_gettype_cobj v1 the_state.b in
    let typ2 = build_gettype_cobj v2 the_state.b in
    let typ1_as_int = L.build_ptrtoint typ1 int_t "typ1_as_int" the_state.b in
    let typ2_as_int = L.build_ptrtoint typ2 int_t "typ2_as_int" the_state.b in
    let diff = L.build_sub typ1_as_int typ2_as_int "diff" the_state.b in
    let invalid_arg = L.build_icmp L.Icmp.Ne diff (L.const_int int_t 0) "invalid_type" the_state.b in
      ignore(L.build_cond_br invalid_arg bad_arg_bb proceed_bb the_state.b);
    let err_message =
      let info = message in
        L.build_global_string info "error message" bad_arg_bd in
    let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_arg_bd in
      ignore(L.build_call printf_func [| str_format_str1 ; err_message |] "printf" bad_arg_bd);
      ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_arg_bd);
    let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
      ignore(L.build_br proceed_bb bad_arg_bd); the_state
  in
  let check_explicit_type t1 v1 message the_state = 
    if not !exceptions then the_state else
    let bad_arg_bb = L.append_block context "bad_type" the_state.func in
    let bad_arg_bd = L.builder_at_end context bad_arg_bb in
    let proceed_bb = L.append_block context "proceed" the_state.func in
    let typ1 = (match ctype_of_ASTtype t1 with 
      | None -> raise (Failure "CodegenError: unexpected type in runtime error checking") 
      | Some x -> x
    ) in
    let typ2 = build_gettype_cobj v1 the_state.b in
    let typ1_as_int = L.build_ptrtoint typ1 int_t "typ1_as_int" the_state.b in
    let typ2_as_int = L.build_ptrtoint typ2 int_t "typ2_as_int" the_state.b in
    let diff = L.build_sub typ1_as_int typ2_as_int "diff" the_state.b in
    let invalid_arg = L.build_icmp L.Icmp.Ne diff (L.const_int int_t 0) "invalid_type" the_state.b in
      ignore(L.build_cond_br invalid_arg bad_arg_bb proceed_bb the_state.b);
    let err_message =
      let info = message in
        L.build_global_string info "error message" bad_arg_bd in
    let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_arg_bd in
      ignore(L.build_call printf_func [| str_format_str1 ; err_message |] "printf" bad_arg_bd);
      ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_arg_bd);
    let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
      ignore(L.build_br proceed_bb bad_arg_bd); the_state
  in
  let check_bounds list_ptr n_ptr message the_state = 
    if not !exceptions then the_state else

    let proceed_bb = L.append_block context "proceed" the_state.func in
    let bad_acc_bb = L.append_block context "bad_acc" the_state.func in
    let bad_acc_bd = L.builder_at_end context bad_acc_bb in
     let idx_arg = build_getdata_cobj int_t n_ptr the_state.b in
     let list_ptr = build_getlist_cobj list_ptr the_state.b in
     let length = build_getlen_clist list_ptr the_state.b in
     let lt_length = L.build_icmp L.Icmp.Sge idx_arg length "lt_length" the_state.b in 
     let gt_zero = L.build_icmp L.Icmp.Slt idx_arg (L.const_int int_t 0) "gt_zero" the_state.b in 
     let outofbounds = L.build_or lt_length gt_zero "inbounds" the_state.b in
       ignore(L.build_cond_br outofbounds bad_acc_bb proceed_bb the_state.b);
     let err_message =
       let info = message in
         L.build_global_string info "error message" bad_acc_bd in
     let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_acc_bd in
       ignore(L.build_call printf_func [| str_format_str1; err_message |] "printf" bad_acc_bd);
       ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_acc_bd);
     let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
       ignore(L.build_br proceed_bb bad_acc_bd); the_state
  in
  let build_getidx_list list_pointer index_pointer the_state =
    let fn_p = build_getctypefn_cobj ctype_idx_idx list_pointer the_state.b in
    let the_state = check_null fn_p "RuntimeError: unsupported operand type(s) for list access" the_state in
    let the_state = check_explicit_type Int index_pointer "RuntimeError: unsupported operand type(s) for list access" the_state in
    let the_state = check_bounds list_pointer index_pointer "RuntimeError: list index out of bounds" the_state in
    let result = L.build_call fn_p [| list_pointer ; index_pointer |] "binop_result" the_state.b in
    (Box(result), the_state)
  in
  let build_getidx_parent_list list_pointer index_pointer the_state =
    let fn_p = build_getctypefn_cobj ctype_idx_parent_idx list_pointer the_state.b in
    let the_state = check_null fn_p "RuntimeError: unsupported operand type(s) for list assignment" the_state in
    let the_state = check_explicit_type Int index_pointer "RuntimeError: unsupported index type for list access" the_state in
    let the_state = check_bounds list_pointer index_pointer "RuntimeError: list index out of bounds" the_state in
    let result = L.build_call fn_p [| list_pointer ; index_pointer |] "parent_binop_result" the_state.b in
    (Box(result), the_state)
  in
  let raise_failure message the_state = 
    if not !exceptions then the_state else
    let err_message = 
    let info = message in
    L.build_global_string info "error message" the_state.b in
    let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" the_state.b in
    ignore(L.build_call printf_func [| str_format_str1; err_message |] "printf" the_state.b);
    ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" the_state.b); the_state
  in
  let rec expr the_state typed_e = 
      let (namespace,the_function) = (the_state.namespace,the_state.func) in
      let (e, ty) = typed_e in
      (match e with
    | SCast (from_type, to_type, expr) -> (raise (Failure "CodegenError: Type casting not implemented in codegen!"))
    | SMethod (obj, name, args) -> (raise (Failure "CodegenError: Methods not implemented in codegen!"))
    | SField (obj, name) -> (raise (Failure "CodegenError: Methods not implemented in codegen!"))
    | SLit lit -> let (res, the_state) = (match lit with
        | IntLit i -> (Raw(L.const_int int_t i), the_state)
        | BoolLit i -> (Raw(L.const_int bool_t (if i then 1 else 0)), the_state)
        | FloatLit i -> (Raw((L.const_float float_t i)), the_state)
        | StringLit i -> let elements = List.rev (List.fold_left (fun l ch ->
            let cobj_of_char_ptr = build_new_cobj_init char_t (L.const_int char_t (Char.code ch)) the_state.b in
            cobj_of_char_ptr :: l) [] (explode i)) in
          let (objptr, dataptr) = build_new_cobj cstring_t the_state.b in 
          let _ = build_new_clist dataptr elements the_state.b in
            (Box(objptr), the_state)
        ) in (res, the_state)
    | SVar name ->
        (match (lookup namespace (Bind(name, ty))) with
          | RawAddr(addr) -> (Raw(L.build_load addr name the_state.b),the_state)
          | BoxAddr(addr, needs_update) ->
            let the_state = check_defined addr ("RuntimeError: name '" ^ name ^ "' is not defined") the_state in 
            let the_state = rebox_if_needed (BoxAddr(addr, needs_update)) name the_state in
            (Box(L.build_load addr name the_state.b),the_state)
        )
    | SBinop(e1, op, e2) ->
      let (_, ty1) = e1
      and (_, ty2) = e2 in
      let (e1',the_state) = expr the_state e1 in
      let (e2',the_state) = expr the_state e2 in
      let generic_binop box1 box2 = 
          let (Box(v1), Box(v2)) = (box1, box2) in
          let fn_idx = (match op with
            | Add      -> ctype_add_idx
            | Sub      -> ctype_sub_idx
            | Mul      -> ctype_mul_idx
            | Div      -> ctype_div_idx
            | Mod      -> ctype_mod_idx
            | Exp      -> ctype_exp_idx
            | Eq       -> ctype_eq_idx
            | Neq      -> ctype_neq_idx
            | Less     -> ctype_lesser_idx
            | Leq      -> ctype_leq_idx
            | Greater  -> ctype_greater_idx
            | Geq      -> ctype_geq_idx
            | And      -> ctype_and_idx
            | Or       -> ctype_or_idx
            | ListAccess -> ctype_idx_idx ) in
        (match op with 
          | ListAccess -> build_getidx_list v1 v2 the_state
          | _ -> 
            let fn_p = build_getctypefn_cobj fn_idx v1 the_state.b in
            let the_state = check_null fn_p ("RuntimeError: unsupported operand type(s) for binary " ^ (Util.binop_to_string op)) the_state in
            let the_state = check_same_type v1 v2 ("RuntimeError: unsupported operand type(s) for binary " ^ (Util.binop_to_string op)) the_state in
            let result = L.build_call fn_p [| v1 ; v2 |] "binop_result" the_state.b in
            (Box(result), the_state))
      in
      let (res, the_state) = (match (e1', e2') with
          | (Raw(v1), Raw(v2)) ->
              let binop_instruction = (match ty1 with  
                |Int|Bool -> (match op with
                  | Add     -> L.build_add
                  | Sub     -> L.build_sub
                  | Mul    -> L.build_mul
                  | Div     -> L.build_sdiv
                  | Mod     -> L.build_srem
                  | Exp     -> build_pow
                  | Eq   -> L.build_icmp L.Icmp.Eq
                  | Neq     -> L.build_icmp L.Icmp.Ne
                  | Less    -> L.build_icmp L.Icmp.Slt
                  | Leq     -> L.build_icmp L.Icmp.Sle
                  | Greater -> L.build_icmp L.Icmp.Sgt
                  | Geq     -> L.build_icmp L.Icmp.Sge
                  | And     -> L.build_and
                  | Or      -> L.build_or
                )
                |Float -> (match op with
                  | Add     -> L.build_fadd
                  | Sub     -> L.build_fsub
                  | Mul     -> L.build_fmul
                  | Div     -> L.build_fdiv
                  | Mod     -> L.build_frem
                  | Exp     -> build_fpow
                  | Eq      -> L.build_fcmp L.Fcmp.Oeq
                  | Neq     -> L.build_fcmp L.Fcmp.One
                  | Less    -> L.build_fcmp L.Fcmp.Olt
                  | Leq     -> L.build_fcmp L.Fcmp.Ole
                  | Greater -> L.build_fcmp L.Fcmp.Ogt
                  | Geq     -> L.build_fcmp L.Fcmp.Oge
                  | And | Or ->
                      raise (Failure "CodegenError: internal error: semant should have rejected and/or on float")
                )
            ) in
              (Raw(binop_instruction v1 v2 "binop_result" the_state.b),the_state)
          | (Box(boxval),Raw(rawval)) -> 
            generic_binop (Box(boxval)) (build_temp_box rawval ty2 the_state.b)
          | (Raw(rawval),Box(boxval)) -> 
            generic_binop (build_temp_box rawval ty1 the_state.b) (Box(boxval))
          | (Box(v1), Box(v2)) -> generic_binop (Box(v1)) (Box(v2))
        ) in (res,the_state)
      | SCall(fexpr, arg_expr_list, SStage(entry_transforms, _, exit_transforms)) -> 
        let the_state = stmt the_state entry_transforms in
        let argc = List.length arg_expr_list in
        let eval_arg aggreg e =
            let (the_state, args) = aggreg in
            let (res, the_state) = expr the_state e in
            (the_state,res::args)
        in
        let (the_state, arg_dataunits) = List.fold_left eval_arg (the_state,[]) (List.rev arg_expr_list) in
        let arg_types = List.map (fun (_,ty) -> ty) arg_expr_list in
        let transform_if_needed raw_ty = function
            | Box(v) -> Box(v)
            | Raw(v) -> build_temp_box v raw_ty the_state.b
        in
        let boxed_args = List.map2 transform_if_needed arg_types arg_dataunits in
        let llargs = List.map (fun b -> match b with Box(v) -> v) boxed_args in
        let cobj_p_arr_t = L.array_type cobj_pt argc in
        let argv_as_arr = L.build_alloca cobj_p_arr_t "argv_arr" the_state.b in
        let store_arg llarg idx =
          let gep_addr = L.build_gep argv_as_arr [|L.const_int int_t 0; L.const_int int_t idx|] "arg" the_state.b in
          ignore(L.build_store llarg gep_addr the_state.b);()
        in
        ignore(List.iter2 store_arg llargs (seq argc));
        let argv = L.build_bitcast argv_as_arr cobj_ppt "argv" the_state.b in
        let (Box(caller_cobj_p),the_state) = expr the_state fexpr in
        let call_ptr = build_getctypefn_cobj ctype_call_idx caller_cobj_p the_state.b in
        let result = L.build_call call_ptr [|caller_cobj_p;argv|] "result" the_state.b in
        let the_state = stmt the_state exit_transforms in
        (Box(result),the_state)
      | SCall(fexpr, arg_expr_list, SFunc(sfdecl)) -> 
        let (_, the_state) = expr the_state fexpr in
        let eval_arg aggreg e =
            let (the_state, args) = aggreg in
            let (res, the_state) = expr the_state e in
            (the_state, res::args)
        in
        let get_binds lhs rhs =
          let Bind (name, explicit_type) = lhs in 
          let (_, tp_rhs) = rhs in 
          match tp_rhs with
              | Dyn -> (Bind(name, explicit_type), explicit_type)
              | _ -> (Bind(name, tp_rhs), explicit_type)
        in let binds = List.map2 get_binds sfdecl.sformals arg_expr_list in
        let (typed_formals, explicit_types) = List.split binds in
        let arg_types = List.map (fun (Bind(_, ty), _) -> ty) binds in
        let arg_lltypes = List.map ltyp_of_typ arg_types in
        let (the_state, arg_dataunits) = List.fold_left eval_arg (the_state, []) (List.rev arg_expr_list) in
        let unwrap (the_state, out) (box, (Bind(name, _), tp_lhs)) = (match (box, tp_lhs) with  
            | Raw(v), _ -> (the_state, v :: out)
            | Box(v), Dyn -> (the_state, v :: out)
            | Box(v), typ -> let the_state = check_explicit_type tp_lhs v ("RuntimeError: invalid type assigned to " ^ name) the_state in 
                (match typ with 
                  | FuncType | Arr | String -> (the_state, v :: out)
                  | _ -> let data = build_getdata_cobj (ltyp_of_typ tp_lhs) v the_state.b in (the_state, data :: out)
                )
          )
        in let (the_state, arg_vals) = List.fold_left unwrap (the_state, []) (List.combine arg_dataunits binds) in
        let arg_vals = List.rev arg_vals in
        let optim_func = (match (SfdeclMap.find_opt sfdecl the_state.optim_funcs) with
          | Some(optim_func) ->  optim_func
          | None -> 
            let formal_types = (Array.of_list arg_types) in
            let ftype = L.function_type (ltyp_of_typ sfdecl.styp) (Array.of_list arg_lltypes) in
            let optim_func = L.define_function sfdecl.sfname ftype the_module in
            let fn_builder = L.builder_at_end context (L.entry_block optim_func) in  
            let fn_namespace = build_binding_list (Some(fn_builder)) (typed_formals @ sfdecl.slocals) false in
            let vals_to_store = Array.to_list (L.params optim_func) in
            let addr_of_bind (bind, _) = match (lookup fn_namespace bind) with 
                |RawAddr(addr) -> addr
                |BoxAddr(addr,_) -> addr
            in
            let addrs = List.map addr_of_bind binds in
            let fn_state = change_state the_state (S_list([S_names(fn_namespace); S_func(optim_func); S_b(fn_builder); S_rettyp(sfdecl.styp); S_generic_func(false)])) in
            ignore(List.iter2 (fun addr value -> ignore(L.build_store value addr fn_state.b)) addrs vals_to_store);
            let fn_state = stmt fn_state sfdecl.sbody in  
            let ret_instr = (match sfdecl.styp with
              | Null -> (fun b ->  L.build_ret (build_new_cobj_init int_t (L.const_int int_t 0) b) b)
              | Dyn -> (fun b ->  L.build_ret (build_new_cobj_init int_t (L.const_int int_t 0) b) b)
              | _ -> (fun b ->  L.build_ret (const_of_typ sfdecl.styp) b)
            ) in 
            let fn_state = add_terminal fn_state ret_instr in optim_func
        ) in
        let result = L.build_call optim_func (Array.of_list arg_vals) "result" the_state.b in
        let the_state = change_state the_state (S_optimfuncs(SfdeclMap.add sfdecl optim_func the_state.optim_funcs)) in
        let res = (match sfdecl.styp with
            | Int | Float | Bool -> Raw(result)
            | _ -> Box(result)
        ) in (res, the_state)
    | SListAccess(e1, e2)  -> expr the_state (SBinop(e1, ListAccess, e2), ty) 
    | SUnop(op, e1) ->
      let (_,ty1) = e1 in
      let (e1',the_state) = expr the_state e1 in
      let (res,the_state) = (match e1' with
      | Box(v1) ->
          let fn_idx = match op with
            | Neg         -> ctype_neg_idx
            | Not         -> ctype_not_idx in
          let fn_p = build_getctypefn_cobj fn_idx v1 the_state.b in
          let bad_op_bb = L.append_block context "bad_op" the_state.func in
          let bad_op_bd = L.builder_at_end context bad_op_bb in
          let proceed_bb = L.append_block context "proceed" the_state.func in
          let invalid_op = L.build_is_null fn_p "invalid_op" the_state.b in
            ignore(L.build_cond_br invalid_op bad_op_bb proceed_bb the_state.b);
          let err_message =
            let info = "RuntimeError: unsupported operand type for unary " ^ (Util.unop_to_string op) in
              L.build_global_string info "error message" bad_op_bd in
          let str_format_str1 = L.build_global_stringptr  "%s\n" "fmt" bad_op_bd in
            ignore(L.build_call printf_func [| str_format_str1 ; err_message |] "printf" bad_op_bd);
            ignore(L.build_call exit_func [| (L.const_int int_t 1) |] "exit" bad_op_bd);
          let the_state = change_state the_state (S_b(L.builder_at_end context proceed_bb)) in
          ignore(L.build_br proceed_bb bad_op_bd);
          let result = L.build_call fn_p [| v1 |] "uop_result" the_state.b in
          (Box(result), the_state)
        |Raw(v1) ->
                let res  = (match op with
            | Neg when ty1=Float         -> L.build_fneg
            | Neg         -> L.build_neg
            | Not         -> L.build_not
          ) v1 "unop_result" the_state.b in
                (Raw(res),the_state)
        ) in (res,the_state)
    | SList(el, t) ->
        let transform_if_needed raw_ty = function
            |Box(v) -> Box(v)
            |Raw(v) -> match raw_ty with 
                | Dyn -> raise (Failure "CodegenError: unexpected type encountered in list passed from semant")
                | _ -> build_temp_box v raw_ty the_state.b
        in
      let (elements, the_state) = List.fold_left (fun (l, the_state) e -> 
        let (element, the_state) = expr the_state e in let (_, typ) = e in 
          ((element, typ) :: l, the_state)) ([], the_state) (List.rev el) in
      let (objptr, dataptr) = build_new_cobj clist_t the_state.b in
       let elements = List.map (fun (elem, t) -> match (transform_if_needed t elem) with Box(v) -> v) elements in
      let _ = build_new_clist dataptr elements the_state.b in
        (Box(objptr), the_state))
  and add_terminal the_state instr = 
      (match (L.block_terminator (L.insertion_block the_state.b)) with  
	    | Some _ -> ()
      | None -> ignore (instr the_state.b)
    ); the_state
  and rip_from_inner_state old inner =
    change_state old (S_list([S_names(inner.namespace);S_optimfuncs(inner.optim_funcs)]))
  and stmt the_state s =
      let (namespace,the_function) = (the_state.namespace, the_state.func) in
      match s with
      | SBlock s -> List.fold_left stmt the_state s
      | SExpr e ->  let (_,the_state) = expr the_state e in the_state
      | SContinue -> raise (Failure ("CodegenError: Continue has not been implemented for codegen"))
      | SBreak -> raise (Failure ("CodegenError: Break has not been implemented for codegen"))
      | SClass(a, b) -> raise (Failure ("CodegenError: Class has not been implemented for codegen"))
      | SAsn (lvalue_list, e) ->
        let (_, tp_rhs) = e in
        let (e', the_state) = expr the_state e in
        let get_addrs (the_state, out) = function
          | SLVar Bind(name, explicit_t) -> (match tp_rhs with
              | Dyn -> (the_state, (lookup namespace (Bind (name, explicit_t)), name, explicit_t) :: out)
              | _ -> (the_state, (lookup namespace (Bind(name, tp_rhs)), name, explicit_t) :: out)
          )
          | SLListAccess (e, idx) -> 
              let (Box(lpointer), the_state) = expr the_state e in
              let (idx, the_state) = expr the_state idx in
              let idx = (match idx with
                | Raw(rawval) -> let Box(newval) = build_temp_box rawval Int the_state.b in newval
                | Box(boxval) -> boxval
              ) in
              let (Box(result), the_state) = build_getidx_parent_list lpointer idx the_state in
              (the_state, (BoxAddr(result, false), "list_access", Dyn) :: out)
        in let (the_state, addrs) = List.fold_left get_addrs (the_state, []) lvalue_list in
        let addrs = List.rev addrs in
        let do_store lhs rhs the_state =
          let (lbind, name, explicit_t) = lhs in
          let the_state = (match rhs with
            | Raw(v) -> (match lbind with
               | RawAddr(addr) -> ignore(L.build_store v addr the_state.b); the_state
               | BoxAddr(addr, _) -> 
                    let Box(data) = build_temp_box v tp_rhs the_state.b in 
                    ignore(L.build_store data addr the_state.b); the_state
             )
            | Box(v) ->
                let the_state = (match explicit_t with
                  | Dyn -> the_state
                  | _ ->  check_explicit_type explicit_t v ("RuntimeError: invalid type assigned to " ^ name) the_state
               )
               in (match lbind with
                   | RawAddr(addr) -> 
                      let data = build_getdata_cobj (ltyp_of_typ explicit_t) v the_state.b in 
                      ignore(L.build_store data addr the_state.b); the_state
                   | BoxAddr(addr, _) -> ignore(L.build_store v addr the_state.b); the_state
                  )
          ) in the_state
        in let the_state = List.fold_left (fun the_state lhs ->
          let the_state = do_store lhs e' the_state in the_state) the_state addrs in
        the_state
      | SNop -> the_state
      | SType e -> the_state
      | SPrint e ->
            let (_, t) = e in
            let (res, the_state) = expr the_state e in
            (match res with
                | Raw(v) ->  (match t with
                    | Int -> ignore(L.build_call printf_func [| int_format_str ; v |] "printf" the_state.b);  the_state
                    | Float -> ignore(L.build_call printf_func [| float_format_str ; v |] "printf" the_state.b);  the_state
                    | Bool -> ignore(L.build_call printf_func [| int_format_str ; v |] "printf" the_state.b);  the_state
                    | _ -> ignore(L.build_call printf_func [| string_format_str ; v |] "printf" the_state.b);  the_state
                )
                | Box(v) -> 
                    let fn_p = build_getctypefn_cobj ctype_print_idx v the_state.b in
                    ignore(L.build_call fn_p [|v|] "print_cob" the_state.b); 
                    ignore(L.build_call printf_func [| newline_format_str ; L.const_int int_t 0 |] "printf" the_state.b); the_state
            )
      | SIf (predicate, then_stmt, else_stmt) ->
        let (_, typ) = predicate in
        let (e, the_state) = expr the_state predicate in 
        let (bool_val, the_state) = (match e with
          | Raw(v) -> (v, the_state)
          | Box(v) -> 
              let the_state = 
                if typ = Dyn then check_explicit_type Bool v ("RuntimeError: invalid boolean type in if statement") the_state 
                else the_state 
              in (build_getdata_cobj bool_t v the_state.b, the_state)
        ) in
        let merge_bb = L.append_block context "merge" the_function in  
        let build_br_merge = L.build_br merge_bb in 
        let then_bb = L.append_block context "then" the_function in
        let then_state = change_state the_state (S_b(L.builder_at_end context then_bb)) in
        let then_state = add_terminal (stmt then_state then_stmt) build_br_merge in
        let the_state = rip_from_inner_state the_state then_state in
        let else_bb = L.append_block context "else" the_function in
        let else_state = change_state the_state (S_b(L.builder_at_end context else_bb)) in
        let else_state = add_terminal (stmt else_state else_stmt) build_br_merge in
        let the_state = rip_from_inner_state the_state else_state in
        ignore(L.build_cond_br bool_val then_bb else_bb the_state.b);  
        let the_state = change_state the_state (S_b(L.builder_at_end context merge_bb)) in 
        the_state
      | SWhile (predicate, body) ->
        let pred_bb = L.append_block context "while" the_function in
        ignore(L.build_br pred_bb the_state.b);
        let body_bb = L.append_block context "while_body" the_function in
        let body_state = change_state the_state (S_b(L.builder_at_end context body_bb)) in
        let body_state = add_terminal (stmt body_state body) (L.build_br pred_bb) in
        let the_state = rip_from_inner_state the_state body_state in
        let pred_state = change_state the_state (S_b(L.builder_at_end context pred_bb)) in
        let (_, t) = predicate in
        let (e, pred_state) = expr pred_state predicate in 
        let (bool_val, pred_state) = (match e with
          |Raw(v) -> (v, pred_state)
          |Box(v) -> let pred_state = check_explicit_type Bool v  ("RuntimeError: invalid boolean type in while statement") pred_state in (build_getdata_cobj bool_t v pred_state.b, pred_state)
        ) in
        let the_state = rip_from_inner_state the_state pred_state in
        let merge_bb = L.append_block context "merge" the_function in
        ignore(L.build_cond_br bool_val body_bb merge_bb pred_state.b);
        let merge_state = change_state the_state (S_b(L.builder_at_end context merge_bb)) in 
        merge_state
      | SFor(var, lst, body) ->
         let (Box(objptr), the_state) = expr the_state lst in
         let listptr = build_getlist_cobj objptr the_state.b in
         let (idxptr, nptr) = build_new_cobj int_t the_state.b in
         ignore(L.build_store (L.const_int int_t 0) nptr the_state.b);
         let ln = build_getlen_clist listptr the_state.b in
         let iter_bb = L.append_block context "iter" the_function in
           ignore(L.build_br iter_bb the_state.b);
         let iter_builder = L.builder_at_end context iter_bb in
         let n = L.build_load nptr "n" iter_builder in
         let nnext = L.build_add n (L.const_int int_t 1) "nnext" iter_builder in
         let iter_complete = (L.build_icmp L.Icmp.Sge) n ln "iter_complete" iter_builder in 
         let body_bb = L.append_block context "for_body" the_function in
         let body_builder = L.builder_at_end context body_bb in
         let fn_p = build_getctypefn_cobj ctype_idx_idx objptr body_builder in
         let elmptr = L.build_call fn_p [|objptr; idxptr|] "idx_cob" body_builder in
        ignore(L.build_store nnext nptr body_builder);
         let the_state = change_state the_state (S_b(body_builder)) in
         let Bind(name, explicit_t) = var in
         let the_state = (match (lookup namespace var) with
              | BoxAddr(var_addr, _) -> ignore(L.build_store elmptr var_addr the_state.b); the_state
              | RawAddr(var_addr) -> 
                  
                  let the_state = check_explicit_type explicit_t elmptr ("RuntimeError: invalid type assigned to " ^ name) the_state in
                  let rawdata = build_getdata_cobj (ltyp_of_typ explicit_t) elmptr the_state.b in
                  ignore(L.build_store rawdata var_addr the_state.b); the_state
          ) in
         ignore(add_terminal (stmt the_state body) (L.build_br iter_bb));
         let merge_bb = L.append_block context "merge" the_function in
           ignore(L.build_cond_br iter_complete merge_bb body_bb iter_builder);
         let the_state = change_state the_state (S_b(L.builder_at_end context merge_bb)) in
           the_state
    | SRange(var, upper, body) ->
         let Bind(name, explicit_t) = var in 
         let (upperdata, the_state) = (match (expr the_state upper) with
          | (Box(objptr), the_state) -> let the_state = check_explicit_type Int objptr ("RuntimeError: invalid type in range loop" ^ name) the_state in
              let data = build_getdata_cobj int_t objptr the_state.b in (data, the_state)
          | (Raw(rawptr), the_state) -> (rawptr, the_state)) in 
         let (idxptr, nptr) = build_new_cobj int_t the_state.b in
         ignore(L.build_store (L.const_int int_t 0) nptr the_state.b);
         let iter_bb = L.append_block context "iter" the_function in
           ignore(L.build_br iter_bb the_state.b);
         let iter_builder = L.builder_at_end context iter_bb in
         let n = L.build_load nptr "n" iter_builder in
         let nnext = L.build_add n (L.const_int int_t 1) "nnext" iter_builder in
         let iter_complete = (L.build_icmp L.Icmp.Sge) n upperdata "iter_complete" iter_builder in
         let body_bb = L.append_block context "range_body" the_function in
         let body_builder = L.builder_at_end context body_bb in
         let the_state = change_state the_state (S_b(body_builder)) in
         let the_state = (match (lookup namespace var) with
              | BoxAddr(var_addr, _) -> 
                  let Box(data) = build_temp_box n Int the_state.b in 
                  ignore(L.build_store data var_addr the_state.b); the_state
              | RawAddr(var_addr) -> 
                  ignore(L.build_store n var_addr the_state.b); the_state
          ) in
         ignore(L.build_store nnext nptr the_state.b);
         ignore(add_terminal (stmt the_state body) (L.build_br iter_bb));
         let merge_bb = L.append_block context "merge" the_function in
           ignore(L.build_cond_br iter_complete merge_bb body_bb iter_builder);
         let the_state = change_state the_state (S_b(L.builder_at_end context merge_bb)) in
           the_state
    | SReturn e -> let (_, ty) = e in
        let (res, the_state) = expr the_state e in
        let the_state = (match the_state.generic_func with
          | false ->  (match ty with
            | Null -> raise (Failure "CodegenError: unexpected empty return type in SReturn")
            | _ -> let (data, the_state) = (match res with
                | Raw(v) -> (match the_state.ret_typ with
                    | Dyn -> (match (build_temp_box v ty the_state.b) with Box(v) -> (v, the_state))
                    | _ -> 
                      if ty <> the_state.ret_typ then 
                      let the_state = raise_failure ("RuntimeError: invalid return type (expected " ^ (string_of_typ the_state.ret_typ) ^ ")") the_state 
                      in ((const_of_typ the_state.ret_typ), the_state)
                      else (v, the_state)
                )
                | Box(v) -> (match the_state.ret_typ with
                    | Dyn -> (v, the_state)
                    | _ -> 
                      let the_state = check_explicit_type the_state.ret_typ v ("RuntimeError: invalid return type (expected " ^ (string_of_typ the_state.ret_typ) ^ ")") the_state in
                      if the_state.ret_typ = FuncType || the_state.ret_typ = Arr || the_state.ret_typ = String then 
                        (v, the_state) 
                      else 
                        let data = build_getdata_cobj (ltyp_of_typ the_state.ret_typ) v the_state.b in (data, the_state)
                )
            ) in ignore(L.build_ret data the_state.b); the_state
          )
          | true -> 
            let (data, the_state) = (match res with
              | Box(v) -> 
                  (match the_state.ret_typ with
                    | Dyn -> (v, the_state)
                    | _ -> let the_state = check_explicit_type the_state.ret_typ v ("RuntimeError: invalid return type (expected " ^ (string_of_typ the_state.ret_typ) ^ ")") the_state in
                        (v, the_state))
              | Raw(v) -> 
                  (match the_state.ret_typ with
                    | Dyn -> (match (build_temp_box v ty the_state.b) with Box(v) -> (v, the_state))
                    | _ -> if ty <> the_state.ret_typ then 
                      let the_state = raise_failure ("RuntimeError: invalid return type (expected " ^ (string_of_typ the_state.ret_typ) ^ ")") the_state in (L.const_null cobj_pt, the_state)
                      else (match (build_temp_box v ty the_state.b) with Box(v) -> (v, the_state)))
            ) in ignore(L.build_ret data the_state.b); the_state
        ) in the_state
    | SFunc sfdecl ->
        let fname = sfdecl.sfname in
        let the_function = L.define_function fname userdef_fn_t the_module in
        let _ = 
          let (fn_obj,datafieldptr,ctypefieldptr) = build_new_cobj_empty the_state.b in
          let dfp_as_fp = L.build_bitcast datafieldptr (L.pointer_type userdef_fn_pt) "dfp_as_fp" the_state.b in
          ignore(L.build_store the_function dfp_as_fp the_state.b);
          ignore(L.build_store ctype_func ctypefieldptr the_state.b);
          let BoxAddr(boxaddr,_) = (lookup namespace (Bind(fname, FuncType))) in
          ignore(L.build_store fn_obj boxaddr the_state.b)
        in
        let fn_b = L.builder_at_end context (L.entry_block the_function) in
        let local_names = names_of_bindlist sfdecl.slocals
        and formal_names = names_of_bindlist sfdecl.sformals in
        let argc = List.length formal_names
        and argv = Array.get (L.params the_function) 0 in
        let cobj_p_arr_pt = L.pointer_type (L.array_type cobj_pt argc) in
        let formals_arr_p = L.build_bitcast argv cobj_p_arr_pt "formals_arr_p" fn_b in
        let formals_arr = L.build_load formals_arr_p "formals_arr" fn_b in
        let formal_vals = List.map (fun idx -> L.build_extractvalue formals_arr idx ("arg"^(string_of_int idx)) fn_b) (seq argc)  in
        let names_to_dynlist names = 
          List.rev (List.fold_left (fun acc n -> (Bind(n,Dyn))::acc) [] names)
        in
        let fn_state = change_state the_state (S_list([S_b(fn_b); S_func(the_function); S_generic_func(true); S_rettyp(sfdecl.styp)])) in
        let add_formal (nspace, fn_state) bind cobj_p =
          let Bind((name, typ)) = bind in
          (match typ with 
            | Dyn | String | Arr | FuncType -> L.set_value_name name cobj_p;
              let alloca = L.build_alloca cobj_pt name fn_state.b in
              ignore(L.build_store cobj_p alloca fn_state.b);
              (BindMap.add bind (BoxAddr(alloca,false)) nspace, fn_state)
            | _ -> L.set_value_name name cobj_p;
              let alloca = L.build_alloca (ltyp_of_typ typ) name fn_state.b in
              let fn_state = check_explicit_type typ cobj_p ("RuntimeError: invalid type assigned to " ^ name ^ " (expected " ^ (string_of_typ typ) ^ ")") fn_state in 
              let data = build_getdata_cobj (ltyp_of_typ typ) cobj_p fn_state.b in
              ignore(L.build_store data alloca fn_state.b);
              (BindMap.add bind (RawAddr(alloca)) nspace, fn_state))
        in
        let fn_namespace = build_binding_list (Some(fn_b)) sfdecl.slocals false in
        let (fn_namespace, fn_state) = List.fold_left2 add_formal (fn_namespace, fn_state) sfdecl.sformals formal_vals in
        let build_return bld = L.build_ret (build_new_cobj_init int_t (L.const_int int_t 0) bld) bld in
        let fn_state = change_state fn_state (S_list([S_names(fn_namespace)])) in
        let fn_state = add_terminal (stmt fn_state sfdecl.sbody) build_return in
        let the_state = change_state the_state (S_optimfuncs(fn_state.optim_funcs)) in
        the_state
    | SStage (entry, body, exit) -> 
      let the_state = stmt the_state entry in 
      let the_state = stmt the_state body in 
      let the_state = stmt the_state exit in the_state
    | STransform (name, from_ty, to_ty) -> 
      (match (from_ty, to_ty) with
       | (x, y) when x = y -> the_state
       | (String, Dyn) | (Dyn, String) | (Arr, Dyn) | (Dyn, Arr) | (FuncType, Dyn) | (Dyn, FuncType) -> 
          let BoxAddr(box_addr1, _) = lookup the_state.namespace (Bind(name, from_ty))
          and BoxAddr(box_addr2, _) = lookup the_state.namespace (Bind(name, to_ty)) in
          let cobj_addr = L.build_load box_addr1 "load_cobj" the_state.b in
          ignore(L.build_store cobj_addr box_addr2 the_state.b); the_state
       | (Dyn, raw_ty) when raw_ty = Int || raw_ty = Float || raw_ty = Bool ->
         let unchecked_boxaddr = lookup the_state.namespace (Bind(name,Dyn)) in
         let the_state = rebox_if_needed unchecked_boxaddr name the_state in 
         let BoxAddr(box_addr,_) = unchecked_boxaddr in 
         let RawAddr(raw_addr) = lookup the_state.namespace (Bind(name,raw_ty)) in 
         let data_cobj = L.build_load box_addr name the_state.b in
         let data = build_getdata_cobj (ltyp_of_typ raw_ty) data_cobj the_state.b in  
         ignore(L.build_store data raw_addr the_state.b); 
         the_state
       | (raw_ty, Dyn) when raw_ty = Int || raw_ty = Float || raw_ty = Bool ->
         let BoxAddr(box_addr, _) = lookup the_state.namespace (Bind(name, Dyn))
         and RawAddr(raw_addr) = lookup the_state.namespace (Bind(name, raw_ty)) in
         let rawval = L.build_load raw_addr "__load_raw" the_state.b in
         let tempobj = build_new_cobj_init (ltyp_of_typ raw_ty) rawval the_state.b in
         ignore(L.build_store tempobj box_addr the_state.b);
         let the_state = change_state the_state (S_needs_reboxing(name, true)) in
         the_state
      )
  in
  let final_state = stmt init_state (SBlock(fst prgm)) in
  ignore(L.build_ret (L.const_int int_t 0) final_state.b);
  the_module
