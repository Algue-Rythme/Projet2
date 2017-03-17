open Array;;
open Build_ROBDD;;
open Dict_litHash;;
open Dictionary;;
open Expr;;

module OBDD_Build = ROBDD_BUILDER(ROBDD_LITHASH);; (* change here to select the dictionary implementation *)

type tree_sifting = LeafTrue_s | LeafFalse_s | Node_s of literal * int * int;;

module HashTree =
struct
  type t = tree_sifting
  let equal a b = (a=b)
  let hash x = Hashtbl.hash x
end

module HashRobdd =
struct
  type t = robdd
  let equal a b = (a=b)
  let hash x = Hashtbl.hash x
end

module HashInt =
struct
  type t = int
  let equal a b = (a=b)
  let hash x = Hashtbl.hash x
end

module IntHash = Hashtbl.Make(HashInt)
module TreeHash = Hashtbl.Make(HashTree)
module RobddHash = Hashtbl.Make(HashRobdd)

(* New type for the sifting : each int represent a pointer to the child *)
  
type robdd_sifting = {

  mutable root : int; (* the index of the root of the tree *)
  
  mutable lvlTable : tree_sifting list LitHash.t; (* the table of the differents levels of the DAG*)
  mutable size : int; (* size of the DAG, may evolve with swapping *)

  mutable renamingTable : literal IntHash.t; (* a hashtable for renaming of variables*)

  mutable lvlLitTable : literal IntHash.t; (* a map to store where each variable is *)
  
  (* memory emulation *)
  mutable node_int : int TreeHash.t; (* mapping node -> index *)
  mutable int_node : tree_sifting IntHash.t; (* mapping index -> node *)
  mutable mem_offset : int; (* the next integer for the mapping *)
  mutable avaible_index : int list; (* List of removed index for garbage collecting *)
} ;;

(* final tree built at the very end of the process *)

let make_robdd_sifting f =
  let tree, nodes = OBDD_Build.create f in
  let n = List.length nodes in
  let lvlTable = LitHash.create 0 in
  let nameTable = IntHash.create 0 and
      actualName = ref 1 in
  let lvlLitTable = IntHash.create 0 in
  let nodeList = ref [] in
  let node_int = TreeHash.create n and
      int_node = IntHash.create n and
      robdd_int = RobddHash.create n
  in
  
  (* index all the nodes -> memory *)
  let rec index_node list c = match list with
    | [] -> ()
    | x::q -> 
       RobddHash.replace robdd_int x c;
      index_node q (c+1) in
  
  let rec make_sifting_mem list = match list with
    | [] -> ()
    | x::q -> make_sifting_mem q;
      let i = RobddHash.find robdd_int x in
      match x with
      | LeafTrue ->
	 IntHash.replace int_node i LeafTrue_s;
	TreeHash.replace node_int LeafTrue_s i;
	nodeList := LeafTrue_s::!nodeList;
	
      | LeafFalse ->
	 IntHash.replace int_node i LeafFalse_s;
	TreeHash.replace node_int LeafFalse_s i;
	nodeList := LeafFalse_s::!nodeList;
	
      | Node(Var(v), fg, fd) -> 
	 let g = RobddHash.find robdd_int fg and
	     d = RobddHash.find robdd_int fd in
	 let node = Node_s(Var(!actualName), g, d) in
	 IntHash.replace nameTable !actualName (Var(v));
	 incr actualName;
	 IntHash.replace int_node i node;
	 TreeHash.replace node_int node i;
	 nodeList := node::!nodeList;
	 
  in
  
  let rec make_lvlTable list =
    let v0 = Var(0) in
    match list with
    | [] -> ()
    | x::q -> make_lvlTable q;
      match x with
      | Node_s(i, _, _) when LitHash.mem lvlTable i ->
	 LitHash.replace lvlTable i (x::(LitHash.find lvlTable i));
      | Node_s(i, _, _) -> LitHash.replace lvlTable i [x];
	let vi = match i with Var(vi)->vi in
	IntHash.replace lvlLitTable vi i;
		
      |  LeafFalse_s | LeafTrue_s -> match LitHash.mem lvlTable v0 with
	| false -> LitHash.replace lvlTable v0 [x]
	| true -> LitHash.replace lvlTable v0 (x::(LitHash.find lvlTable v0))
  in
  index_node nodes 0;
  make_sifting_mem (List.rev nodes); (* list reverted to keep the order on the variables *)
  make_lvlTable !nodeList;
  let s = {root=(RobddHash.find robdd_int tree); lvlTable=lvlTable; size=n;
	   renamingTable=nameTable; lvlLitTable; node_int; int_node;
	   mem_offset=n; avaible_index=[]}
  in
  s;;


(* take a sifting object and gives the shared robdd + the list of the nodes *)
let sift_to_robdd sift =
  let l = ref []
  and hashTbl = RobddHash.create sift.size in
  
  let rec tree_to_robdd tree = match tree with
    | LeafFalse_s ->
       if not (RobddHash.mem hashTbl LeafFalse) then
	 l := LeafFalse::!l;
      RobddHash.replace hashTbl LeafFalse true;
      LeafFalse
    | LeafTrue_s -> 
       if not (RobddHash.mem hashTbl LeafTrue) then 
	 l := LeafTrue::!l;
      RobddHash.add hashTbl LeafTrue true;
      LeafTrue
    | Node_s(Var(v), i, j) ->
       let n = Node(IntHash.find sift.renamingTable v,
		    tree_to_robdd (IntHash.find sift.int_node i),
		    tree_to_robdd (IntHash.find sift.int_node j)) in
       if not (RobddHash.mem hashTbl n) then
	 l:= n::!l;
       RobddHash.replace hashTbl n true;
       n
  in
  let t = tree_to_robdd (IntHash.find sift.int_node sift.root) in
  t, !l;;

(* Take a sifting object and gives the shared robdd + list of all nodes with the renaming *)
let sift_to_bdd_renamed sift =
  let l = ref []
  and hashTbl = RobddHash.create sift.size in
  
  let rec tree_to_robdd tree = match tree with
    | LeafFalse_s ->
       if not (RobddHash.mem hashTbl LeafFalse) then
	 l := LeafFalse::!l;
      RobddHash.replace hashTbl LeafFalse true;
      LeafFalse
    | LeafTrue_s -> 
       if not (RobddHash.mem hashTbl LeafTrue) then 
	 l := LeafTrue::!l;
      RobddHash.add hashTbl LeafTrue true;
      LeafTrue
    | Node_s(v, i, j) ->
       let n = Node(v, tree_to_robdd (IntHash.find sift.int_node i),
		    tree_to_robdd (IntHash.find sift.int_node j)) in
       if not (RobddHash.mem hashTbl n) then
	 l:= n::!l;
       RobddHash.replace hashTbl n true;
       n
  in
  let t = tree_to_robdd (IntHash.find sift.int_node sift.root) in
  t, !l;;


(* Indicate if a node is present in the robdd_sifting *)
let registered_node sift node = TreeHash.mem sift.node_int node;;

(* Remove a node in the robdd_sifting *)
let remove_node sift node =
  sift.size <- (sift.size - 1);
  let v0 = Var(0) in
  let index = TreeHash.find sift.node_int node in
  TreeHash.remove sift.node_int node;
  IntHash.remove sift.int_node index;
  let rec del_list l n = match l with
    | [] -> []
    | x::q when x=n -> del_list q n
    | x::q -> x::(del_list q n) in
  match node with
  | LeafTrue_s | LeafFalse_s ->
     LitHash.replace sift.lvlTable v0 (del_list (LitHash.find sift.lvlTable v0) node)
  | Node_s(x, _, _) ->
     LitHash.replace sift.lvlTable x (del_list (LitHash.find sift.lvlTable x) node)


(* Free the memory for the node *)
let free_node sift node =
  let index = TreeHash.find sift.node_int node in
  sift.avaible_index <- index::sift.avaible_index;
  remove_node sift node;;

let updateIndex sift index node =
  let oldNode = IntHash.find sift.int_node index in
  IntHash.replace sift.int_node index node;
  TreeHash.replace sift.node_int node index
;;

let add_node_if_not_present sift node =
  if registered_node sift node then
    TreeHash.find sift.node_int node
  else begin
    sift.size <- (sift.size + 1);
    match node with
    | LeafFalse_s | LeafTrue_s -> failwith "Adding a Leaf"
    | Node_s(v, i, j) -> 
       if LitHash.mem sift.lvlTable v then
	 LitHash.replace sift.lvlTable v (node::(LitHash.find sift.lvlTable v))
       else
	 LitHash.replace sift.lvlTable v [node];
      
      match sift.avaible_index with
      | [] ->
	 let index = sift.mem_offset in
	 sift.mem_offset <- index+1;
	 IntHash.replace sift.int_node index node;
	 TreeHash.replace sift.node_int node index;
	 index
      | index::q ->
	 sift.avaible_index <- q;
	IntHash.replace sift.int_node index node;
	TreeHash.replace sift.node_int node index;
	index
  end
