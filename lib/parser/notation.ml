open Bwd
open Util
open Core
open Raw
open Reporter
module TokMap = Map.Make (Token)
open Asai.Range

type token_ws = Token.t * (Whitespace.t list * Asai.Range.t option)
type ss_token_ws = token_ws * (string located * Whitespace.t list) list

(* A notation is either open or closed, on both sides.  We call these two properties combined its "fixity", since they are equivalent to the traditional classification as infix, prefix, postfix, or "outfix".

    left | right | traditional name
   ------|-------|------------------
    open | open  | infix
   closed| open  | prefix
    open |closed | postfix
   closed|closed | closed / outfix / around-fix

   A notation is left-associative, right-associative, or non-associative.  It can only be associative on a side where it is open, i.e. only an infix or prefix notation can meaningfully be right-associative, while only an infix or postfix notation can meaningfully be left-associative.  Thus, instead of storing associativity separately, we store a "strictness" along with openness. *)

type closed = Dummy_closed
type 's opn = Dummy_open
type _ openness = Open : 's No.strictness -> 's opn openness | Closed : closed openness

(* These opennesses are determined by a more traditional fixity. *)
type (_, _, _) fixity =
  | Infix : 'tight No.t -> (No.strict opn, 'tight, No.strict opn) fixity
  | Infixl : 'tight No.t -> (No.nonstrict opn, 'tight, No.strict opn) fixity
  | Infixr : 'tight No.t -> (No.strict opn, 'tight, No.nonstrict opn) fixity
  | Prefix : 'tight No.t -> (closed, 'tight, No.strict opn) fixity
  | Prefixr : 'tight No.t -> (closed, 'tight, No.nonstrict opn) fixity
  | Postfix : 'tight No.t -> (No.strict opn, 'tight, closed) fixity
  | Postfixl : 'tight No.t -> (No.nonstrict opn, 'tight, closed) fixity
  | Outfix : (closed, No.plus_omega, closed) fixity

type wrapped_fixity = Fixity : ('left, 'tight, 'right) fixity -> wrapped_fixity

(* This is where we enforce that an infix notation can't be associative on both sides. *)
let fixprops : type left tight right.
    (left, tight, right) fixity -> left openness * tight No.t * right openness = function
  | Infix t -> (Open Strict, t, Open Strict)
  | Infixl t -> (Open Nonstrict, t, Open Strict)
  | Infixr t -> (Open Strict, t, Open Nonstrict)
  | Prefix t -> (Closed, t, Open Strict)
  | Prefixr t -> (Closed, t, Open Nonstrict)
  | Postfix t -> (Open Strict, t, Closed)
  | Postfixl t -> (Open Nonstrict, t, Closed)
  | Outfix -> (Closed, No.plus_omega, Closed)

(* Notations have an identity that belongs to this extensible variant, parametrized by openness and tightness. *)
type (_, _, _) identity = ..

(* User notations are created at runtime by applications of a generative functor. *)

module type Fixity = sig
  type left
  type tight
  type right
end

(* There is no need to make this functor generative.  See https://discuss.ocaml.org/t/extensible-variants-and-functors/11117/5: "since functors are executed just like functions each time they’re applied, and since extending an extensible variant performs an allocation, constructors of extensible variants resulting from distinct functor applications are not compatible".  *)
module Make (F : Fixity) = struct
  type (_, _, _) identity += User : (F.left, F.tight, F.right) identity
end

(* Notation printers are informed what sort of space or break to end with, if there is not specified whitespace (multiple newlines and/or comments).  These are the options.  `None means no space or break, `Cut means a possible linebreak but no space otherwise, `Break means a possible linebreak and a space otherwise, `Nobreak means a space but not a possible linebreak, and `Hard means always a linebreak.  In PPrint terms these are respectively empty, break 0, break 1, blank 1, and hardline.  These also influence how the whitespace is printed if it is present: if the space is `Cut or `Break or `Hard, we ensure that the whitespace includes at least one possible linebreak (which might not already be the case, e.g. for a block comment containing no linebreaks. *)
type space = [ `None | `Cut | `Break | `Nobreak | `Hard ]

(* A "notation tree" (not to be confused with a "parse tree", which is the *result* of parsing) carries the information about how to parse one or more notations.  Each individual notation is defined by giving one tree, but multiple such trees can also be "merged" together.  This allows different notations that start out looking the same to be parsed with minimal backtracking, as we don't need to "decide" which notation we're parsing until we get to the point of the tree where they diverge.  Accordingly, although each notation is associated to a defining tree, a tree also stores pointers to notations at its leaves, since a merged tree could parse many different notations depending on which path through it is taken. *)

(* The trees corresponding to notations that are open on one side or the other do *not* record the existence of the leftmost or rightmost subterm: they only record the positions of the operators and fully delimited "inner" subterms.  Thus, a notation tree does not fully characterize the behavior of a notation until paired with the information of its openness on each side. *)

(* A notation tree is parametrized by an upper tightness interval and is guaranteed to produce only notations that lie in that interval from the left. *)
type (_, _) tree =
  | Inner : ('t, 's) branch -> ('t, 's) tree
  | Done_open : ('t, 's, 'tight) No.lt * ('left opn, 'tight, 'right) notation -> ('t, 's) tree
  (* However, left-closed notations can lie in any tightness interval on that side. *)
  | Done_closed : (closed, 'tight, 'right) notation -> ('t, 's) tree
  (* Trees associated to notations of arbitrary length are infinite, so we allow them to be computed lazily as needed. *)
  | Lazy : ('t, 's) tree Lazy.t -> ('t, 's) tree
  (* One notation is a prefix of another one.  Reported as an error when reached during parsing, but just saved when notations are created and merged. *)
  | Ambiguity : string list -> ('t, 's) tree
  (* The sub-case when all the ambiguous notations are closed *)
  | Ambiguity_closed : string list -> ('t, 's) tree

(* A map from tokens to trees that remembers in addition whether each token is allowed to be superscripted. *)
and ('t, 's) tokmap = (('t, 's) tree * [ `Ss | `Noss ]) TokMap.t

(* When there is a choice in parsing, we arrange it so that no backtracking is required (except for a single token of lookahead).  We test all the possible next literal tokens, considering the possibility of a notation operator, field, or other term.  (Constructors and identifiers are considered special terms, and extracted during postprocessing.)  Fields cannot also be other terms, and we forbid symbols that occur in operators from also being variable names, so there is no need for backtracking. *)
and ('t, 's) branch = {
  ops : ('t, 's) tokmap;
  field : ('t, 's) tree option;
  term : ('t, 's) tokmap option;
}

(* The entry point of a notation tree must begin with an operator symbol. *)
and ('t, 's) entry = ('t, 's) tokmap

(* If we weren't using intrinsically well-scoped De Bruijn indices, then the typechecking context and the type of raw terms would be simply ordinary types, and we could use the one as the parsing State and the other as the parsing Result.  However, the Fmlib parser isn't set up to allow a parametrized family of state types, with the output of a parsing combinator depending on the state (and it would be tricky to do that correctly anyway).  So instead we record the result of parsing as a syntax tree with idents, and have a separate step of "postprocessing" that makes it into a raw term.  This has the additional advantage that by parsing and pretty-printing we can reformat code even if it is not well-scoped. *)
and observation =
  | Term : ('lt, 'ls, 'rt, 'rs) parse located -> observation
  | Token : token_ws -> observation
  (* Superscripted tokens are only used here when there is at least one superscript. *)
  | Ss_token : ss_token_ws -> observation

and observations =
  | Single of (token_ws, ss_token_ws) Either.t
  | Multiple of
      (token_ws, ss_token_ws) Either.t * observation Bwd.t * (token_ws, ss_token_ws) Either.t

(* A parsed notation, with its own tightness and openness, and lying in specified left and right tightness intervals, has a Bwd of observations in its inner holes, plus possibly a first and/or last term depending on its openness.  It is parametrized by the openness and tightness of the notation, and also by upper tightness intervals from the left and right in which it is guaranteed to lie.  Thus, the first and last term (if any) can be guaranteed statically to be valid, and we may require witnesses that the notation is tight enough on the left and/or the right (also depending on its openness) to fit in the specified intervals.  The whitespace argument stores the comments and whitespace attached after each operator token. *)
and ('left, 'tight, 'right, 'lt, 'ls, 'rt, 'rs) parsed_notn =
  | Infix : {
      first : ('lt, 'ls, 'tight, 'left) parse located;
      inner : observations;
      last : ('tight, 'right, 'rt, 'rs) parse located;
      left_ok : ('lt, 'ls, 'tight) No.lt;
      right_ok : ('rt, 'rs, 'tight) No.lt;
    }
      -> ('left opn, 'tight, 'right opn, 'lt, 'ls, 'rt, 'rs) parsed_notn
  | Prefix : {
      inner : observations;
      last : ('tight, 'right, 'rt, 'rs) parse located;
      right_ok : ('rt, 'rs, 'tight) No.lt;
    }
      -> (closed, 'tight, 'right opn, 'lt, 'ls, 'rt, 'rs) parsed_notn
  | Postfix : {
      first : ('lt, 'ls, 'tight, 'left) parse located;
      inner : observations;
      left_ok : ('lt, 'ls, 'tight) No.lt;
    }
      -> ('left opn, 'tight, closed, 'lt, 'ls, 'rt, 'rs) parsed_notn
  | Outfix : { inner : observations } -> (closed, 'tight, closed, 'lt, 'ls, 'rt, 'rs) parsed_notn

(* A "parse tree" is not to be confused with our "notation trees".  Note that these parse trees don't know anything about the *meanings* of notations either; those are stored by the "postprocessing" functions. *)
and (_, _, _, _) parse =
  | Notn :
      ('left, 'tight, 'right) notation * ('left, 'tight, 'right, 'lt, 'ls, 'rt, 'rs) parsed_notn
      -> ('lt, 'ls, 'rt, 'rs) parse
  (* We treat application as a left-associative binary infix operator of tightness +ω.  Note that like any infix operator, its left argument must be in its left interval and its right argument must be in its right interval. *)
  | App : {
      fn : ('lt, 'ls, No.plus_omega, No.nonstrict) parse located;
      arg : (No.plus_omega, No.strict, 'rt, 'rs) parse located;
      left_ok : ('lt, 'ls, No.plus_omega) No.lt;
      right_ok : ('rt, 'rs, No.plus_omega) No.lt;
    }
      -> ('lt, 'ls, 'rt, 'rs) parse
  (* These all store the whitespace occurring after them. *)
  | Placeholder : Whitespace.t list -> ('lt, 'ls, 'rt, 'rs) parse
  | Ident : string list * Whitespace.t list -> ('lt, 'ls, 'rt, 'rs) parse
  | Constr : string * Whitespace.t list -> ('lt, 'ls, 'rt, 'rs) parse
  | Field : string * string list * Whitespace.t list -> ('lt, 'ls, 'rt, 'rs) parse
  | Superscript :
      ('lt, 'ls, No.plus_omega, No.strict) parse located option * string located * Whitespace.t list
      -> ('lt, 'ls, 'rt, 'rs) parse
  | Hole : {
      li : ('lt, 'ls) No.iinterval;
      ri : ('rt, 'rs) No.iinterval;
      num : int ref;
      ws : Whitespace.t list;
    }
      -> ('lt, 'ls, 'rt, 'rs) parse

(* The entry point of the parse tree defining a particular notation must be parametrized either by the representable non-strict interval at that tightness, or by the empty interval in case of a left-closed notation. *)
and ('left, 'tight) notation_entry =
  | Open_entry : ('tight, No.nonstrict) entry -> ('strict opn, 'tight) notation_entry
  | Closed_entry : (No.plus_omega, No.strict) entry -> (closed, 'tight) notation_entry

(* A notation has a precedence, which we call "tightness" to make it obvious that higher numbers bind more tightly, and is a floating-point number.  Using a DAG for precedence, as in Danielsson-Norell, is a nice idea, but it seems to require a lot of backtracking: if when parsing the right-hand argument of a notation ∧ you encounter a notation * that isn't tighter than ∧, you can't know yet that it is forbidden; you have to keep parsing in case you encounter another notation like = that is tighter than ∧ and looser than *, or in fact multiple such notations forming some arbitrarily complicated path through the DAG.  This is incompatible with the minimal-backtracking approach we take, so we stick to numerical tightnesses.

   Our approach is based on the parsing technique of Pratt.  This means that a notation that's closed on both sides doesn't need a tightness at all (it behaves like the highest possible tightness on a closed side); in practice they end up with +ω.  User-defined notations that are open on at least one side have finite tightness, while +ω and −ω tightness are reserved for internal built-in notations (let-in, abstraction, and ascription are −ω, while all outfix notations such as parentheses (and also, morally, application) have tightness +ω. *)
and ('left, 'tight, 'right) notation =
  ('left, 'tight, 'right) identity * ('left, 'tight, 'right) fixity

type wrapped_identity = Wrap : ('left, 'tight, 'right) identity -> wrapped_identity

(* A match pattern is either a variable name or a constructor with some number of pattern arguments. *)
module Matchpattern = struct
  type t = Var : string option located -> t | Constr : Constr.t located * (t, 'n) Vec.t -> t
end

(* The definition of a notation *)

type ('left, 'tight, 'right) data = {
  name : string;
  tree : ('left, 'tight) notation_entry;
  (* A postproccesing function has to be polymorphic over the length of the context so as to produce intrinsically well-scoped terms.  Thus, we have to wrap it as a field of a record (or object).  The whitespace argument is often ignored, but it allows complicated notation processing functions to be shared between the processor and the printer, and sometimes the processing functions need to inspect the sequence of tokens which is stored with the whitespace. *)
  processor :
    'n. (string option, 'n) Bwv.t -> observation list -> Asai.Range.t option -> 'n check located;
  (* If this notation can be a match pattern, get it. *)
  pattern : observation list -> Asai.Range.t option -> Matchpattern.t;
  (* A printing function for a notation is told the list of arguments of the notation.  It returns the printed document along with its trailing whitespace/comments (so that the caller can place that whitespace outside its group). *)
  print_term : (observation list -> PPrint.document * Whitespace.t list) option;
  (* When printing case tree notations, we split the output into an "introduction" and a "body".  The introduction, such as "match n [", tries to go on the same line as whatever form introduced the case tree (and with a hanging indent under it), such as "def x : A ≔" or "let x : A ≔" or part of an outer case tree construct such as ".field ↦".  The body goes on the same line too if it fits, otherwise it breaks into multiple lines and indents back to the next level below the enclosing case tree construct if any (NOT hanging under the introductory line).  Thus, a case-tree printing function returns two printed documents.

     In addition, we distinguish between "trivial" and "nontrivial" introductions.  A trivial introduction is a 0- or 1-character one, like the opening parenthesis of a tuple.  A trivial introduction is treated specially IF the form introducing the case tree is empty, so that there would literally be only 0 or 1 characters on the introduction line; in that case, there should be no linebreak after the introduction even when the body is being linebreaked.  Thus, the function to print a notation as a case tree must be told whether it is in a trivial context or not (which it may choose to ignore, if it is adding nontrivial introductions). *)
  print_case :
    ([ `Trivial | `Nontrivial ] ->
    observation list ->
    PPrint.document * PPrint.document * Whitespace.t list)
    option;
  (* Whether this notation, with its current arguments, should be printed as a case tree if it's the value of a def or a let. *)
  is_case : observation list -> bool;
}

(* We create a global intrinsically well-typed map that stores the definitions of each notations, identified as above with identity and fixity. *)

module Data = struct
  type (_, _) t =
    | NotnTbl :
        (wrapped_identity, ('left, 'tight, 'right) data) Hashtbl.t
        -> ('left * 'right, 'tight) t
end

module TightMap = No.Map.Make (Data)

type map = {
  mutable infix : (No.strict opn * No.strict opn) TightMap.t;
  mutable infixl : (No.nonstrict opn * No.strict opn) TightMap.t;
  mutable infixr : (No.strict opn * No.nonstrict opn) TightMap.t;
  mutable prefix : (closed * No.strict opn) TightMap.t;
  mutable prefixr : (closed * No.nonstrict opn) TightMap.t;
  mutable postfix : (No.strict opn * closed) TightMap.t;
  mutable postfixl : (No.nonstrict opn * closed) TightMap.t;
  mutable outfix : (wrapped_identity, (closed, No.plus_omega, closed) data) Hashtbl.t;
}

let globals : map =
  {
    infix = TightMap.empty;
    infixl = TightMap.empty;
    infixr = TightMap.empty;
    prefix = TightMap.empty;
    prefixr = TightMap.empty;
    postfix = TightMap.empty;
    postfixl = TightMap.empty;
    outfix = Hashtbl.create 10;
  }

let make : type left tight right. (left, tight, right) notation -> (left, tight, right) data -> unit
    =
 fun (id, fixity) data ->
  match fixity with
  | Infix tight ->
      let idtbl =
        match TightMap.find_opt tight globals.infix with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.infix <- TightMap.add tight (NotnTbl idtbl) globals.infix;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Infixl tight ->
      let idtbl =
        match TightMap.find_opt tight globals.infixl with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.infixl <- TightMap.add tight (NotnTbl idtbl) globals.infixl;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Infixr tight ->
      let idtbl =
        match TightMap.find_opt tight globals.infixr with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.infixr <- TightMap.add tight (NotnTbl idtbl) globals.infixr;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Prefix tight ->
      let idtbl =
        match TightMap.find_opt tight globals.prefix with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.prefix <- TightMap.add tight (NotnTbl idtbl) globals.prefix;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Prefixr tight ->
      let idtbl =
        match TightMap.find_opt tight globals.prefixr with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.prefixr <- TightMap.add tight (NotnTbl idtbl) globals.prefixr;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Postfix tight ->
      let idtbl =
        match TightMap.find_opt tight globals.postfix with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.postfix <- TightMap.add tight (NotnTbl idtbl) globals.postfix;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Postfixl tight ->
      let idtbl =
        match TightMap.find_opt tight globals.postfixl with
        | Some (NotnTbl idtbl) -> idtbl
        | None ->
            let idtbl = Hashtbl.create 10 in
            globals.postfixl <- TightMap.add tight (NotnTbl idtbl) globals.postfixl;
            idtbl in
      Hashtbl.replace idtbl (Wrap id) data
  | Outfix -> Hashtbl.replace globals.outfix (Wrap id) data

let find : type left tight right. (left, tight, right) notation -> (left, tight, right) data =
 fun (id, fixity) ->
  let open Monad.Ops (Monad.Maybe) in
  match
    (match fixity with
     | Infix tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.infix in
         Hashtbl.find_opt idtbl (Wrap id)
     | Infixl tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.infixl in
         Hashtbl.find_opt idtbl (Wrap id)
     | Infixr tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.infixr in
         Hashtbl.find_opt idtbl (Wrap id)
     | Prefix tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.prefix in
         Hashtbl.find_opt idtbl (Wrap id)
     | Prefixr tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.prefixr in
         Hashtbl.find_opt idtbl (Wrap id)
     | Postfix tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.postfix in
         Hashtbl.find_opt idtbl (Wrap id)
     | Postfixl tight ->
         let* (NotnTbl idtbl) = TightMap.find_opt tight globals.postfixl in
         Hashtbl.find_opt idtbl (Wrap id)
     | Outfix -> Hashtbl.find_opt globals.outfix (Wrap id)
      : (left, tight, right) data option)
  with
  | Some data -> data
  | None -> fatal (Anomaly "undefined notation")

(* Wrappers *)

module Notation = struct
  type t = Wrap : ('left, 'tight, 'right) notation -> t
end

type wrapped_parse = Wrap : ('lt, 'ls, 'rt, 'rs) parse Asai.Range.located -> wrapped_parse

module Observations = struct
  type t = observations

  let tok_of_ss = function
    | Either.Left tok -> Token tok
    | Right tok -> Ss_token tok

  let prepend : t -> observation list -> observation list =
   fun obs tail ->
    match obs with
    | Single tok -> tok_of_ss tok :: tail
    | Multiple (tok1, obs, tok2) -> tok_of_ss tok1 :: Bwd.prepend obs (tok_of_ss tok2 :: tail)

  type partial =
    | Single of (token_ws, ss_token_ws) Either.t option
    | Multiple of
        (token_ws, ss_token_ws) Either.t
        * observation Bwd.t
        * (token_ws, ss_token_ws) Either.t option

  let empty : partial = Single None

  let snoc_sstok : partial -> ss_token_ws -> partial =
   fun obs tok ->
    match obs with
    | Single None -> Single (Some (Right tok))
    | Single (Some tok1) -> Multiple (tok1, Emp, Some (Right tok))
    | Multiple (tok1, inner, None) -> Multiple (tok1, inner, Some (Right tok))
    | Multiple (tok1, inner, Some tok2) ->
        Multiple (tok1, Snoc (inner, tok_of_ss tok2), Some (Right tok))

  let snoc_tok : partial -> token_ws -> partial =
   fun obs tok ->
    match obs with
    | Single None -> Single (Some (Left tok))
    | Single (Some tok1) -> Multiple (tok1, Emp, Some (Left tok))
    | Multiple (tok1, inner, None) -> Multiple (tok1, inner, Some (Left tok))
    | Multiple (tok1, inner, Some tok2) ->
        Multiple (tok1, Snoc (inner, tok_of_ss tok2), Some (Left tok))

  let snoc_term : type lt ls rt rs. partial -> (lt, ls, rt, rs) parse located -> partial =
   fun obs tm ->
    match obs with
    | Single None -> raise (Invalid_argument "Observations.snoc_term")
    | Single (Some tok1) -> Multiple (tok1, Snoc (Emp, Term tm), None)
    | Multiple (tok1, inner, None) -> Multiple (tok1, Snoc (inner, Term tm), None)
    | Multiple (tok1, inner, Some tok2) ->
        Multiple (tok1, Snoc (Snoc (inner, tok_of_ss tok2), Term tm), None)

  let of_partial : partial -> t = function
    | Single (Some tok) -> Single tok
    | Single None -> raise (Invalid_argument "Observations.of_partial")
    | Multiple (tok1, inner, Some tok2) -> Multiple (tok1, inner, tok2)
    | Multiple (_, _, None) -> raise (Invalid_argument "Observations.of_partial")
end

let empty_branch = { ops = TokMap.empty; field = None; term = None }

let infix ~notn ~first ~inner ~last ~left_ok ~right_ok =
  Notn (notn, Infix { first; inner; last; left_ok; right_ok })

let prefix ~notn ~inner ~last ~right_ok = Notn (notn, Prefix { inner; last; right_ok })
let postfix ~notn ~first ~inner ~left_ok = Notn (notn, Postfix { first; inner; left_ok })
let outfix ~notn ~inner = Notn (notn, Outfix { inner })

let args : type left tight right lt ls rt rs.
    (left, tight, right, lt, ls, rt, rs) parsed_notn -> observation list = function
  | Infix { first; inner; last; _ } -> Term first :: Observations.prepend inner [ Term last ]
  | Prefix { inner; last; _ } -> Observations.prepend inner [ Term last ]
  | Postfix { first; inner; _ } -> Term first :: Observations.prepend inner []
  | Outfix { inner; _ } -> Observations.prepend inner []

(* When parsing from left to right, we have to return a partial parse tree without knowing yet what tightness interval it will have to be in from the right.  So we return it as a callback that takes that interval as an argument and can fail, returning the name of the offending notation if it fails.  One could argue that instead the allowable tightness intervals should be returned along with the partial parse tree and used to restrict the allowable notations parsed afterwards.  But that would require indexing those pre-merged trees by *two* tightness values, so that we'd have to maintain n² such trees where n is the number of tightness values in use, and that makes me worry a bit about efficiency.  Doing it this way also makes it easier to trap it and issue a more informative error message. *)
type ('lt, 'ls) right_wrapped_parse = {
  get : 'rt 'rs. ('rt, 'rs) No.iinterval -> (('lt, 'ls, 'rt, 'rs) parse located, string) Result.t;
}

(* A partially-wrapped notation that can appear in a specified upper tightness interval on the left. *)
type (_, _) notation_in_interval =
  | Open_in_interval :
      ('lt, 'ls, 'tight) No.lt * ('left opn, 'tight, 'right) notation
      -> ('lt, 'ls) notation_in_interval
  | Closed_in_interval : (closed, 'tight, 'right) notation -> ('lt, 'ls) notation_in_interval

let left (_, d) =
  let l, _, _ = fixprops d in
  l

let tightness (_, d) =
  let _, t, _ = fixprops d in
  t

let right (_, d) =
  let _, _, r = fixprops d in
  r

(* A notation has associated upper tightness intervals on both the left and the right, which specify what tightnesses of other notations can appear in an open subterm on that side.  Thus, both of these intervals start at the tightness of the notation, with their open- or closed-ness determined by its associativity. *)
let interval_left : ('s opn, 'tight, 'right) notation -> ('tight, 's) No.iinterval =
 fun n ->
  let Open strictness, endpoint, _ = fixprops (snd n) in
  { strictness; endpoint }

let interval_right : ('left, 'tight, 's opn) notation -> ('tight, 's) No.iinterval =
 fun n ->
  let _, endpoint, Open strictness = fixprops (snd n) in
  { strictness; endpoint }

let name n = (find n).name
let tree n = (find n).tree
let print_term n = (find n).print_term
let print_case n = (find n).print_case
let processor n = (find n).processor
let pattern n = (find n).pattern

let is_case = function
  | { value = Notn (n, d); _ } -> (find n).is_case (args d)
  | _ -> false

let split_last_whitespace (obs : observations) : observations * Whitespace.t list =
  match obs with
  | Single (Left (tok, (ws, loc))) ->
      let first, rest = Whitespace.split ws in
      (Single (Left (tok, (first, loc))), rest)
  | Single (Right ((tok, (ws, loc)), sups)) ->
      let first, rest = Whitespace.split ws in
      (Single (Right ((tok, (first, loc)), sups)), rest)
  | Multiple (tok1, obs, Left (tok2, (ws2, loc))) ->
      let first, rest = Whitespace.split ws2 in
      (Multiple (tok1, obs, Left (tok2, (first, loc))), rest)
  | Multiple (tok1, obs, Right ((tok2, (ws2, loc)), sups)) ->
      let first, rest = Whitespace.split ws2 in
      (Multiple (tok1, obs, Right ((tok2, (first, loc)), sups)), rest)

let rec split_ending_whitespace : type lt ls rt rs.
    (lt, ls, rt, rs) parse located -> (lt, ls, rt, rs) parse located * Whitespace.t list = function
  | { value; loc } -> (
      match value with
      | Notn (notn, Infix { first; inner; last; left_ok; right_ok }) ->
          let last, rest = split_ending_whitespace last in
          ({ value = Notn (notn, Infix { first; inner; last; left_ok; right_ok }); loc }, rest)
      | Notn (notn, Prefix { inner; last; right_ok }) ->
          let last, rest = split_ending_whitespace last in
          ({ value = Notn (notn, Prefix { inner; last; right_ok }); loc }, rest)
      | Notn (notn, Postfix { first; inner; left_ok }) ->
          let inner, rest = split_last_whitespace inner in
          ({ value = Notn (notn, Postfix { first; inner; left_ok }); loc }, rest)
      | Notn (notn, Outfix { inner }) ->
          let inner, rest = split_last_whitespace inner in
          ({ value = Notn (notn, Outfix { inner }); loc }, rest)
      | App { fn; arg; left_ok; right_ok } ->
          let arg, rest = split_ending_whitespace arg in
          ({ value = App { fn; arg; left_ok; right_ok }; loc }, rest)
      | Placeholder ws ->
          let first, rest = Whitespace.split ws in
          ({ value = Placeholder first; loc }, rest)
      | Ident (x, ws) ->
          let first, rest = Whitespace.split ws in
          ({ value = Ident (x, first); loc }, rest)
      | Constr (c, ws) ->
          let first, rest = Whitespace.split ws in
          ({ value = Constr (c, first); loc }, rest)
      | Field (f, b, ws) ->
          let first, rest = Whitespace.split ws in
          ({ value = Field (f, b, first); loc }, rest)
      | Superscript (x, s, ws) ->
          let first, rest = Whitespace.split ws in
          ({ value = Superscript (x, s, first); loc }, rest)
      | Hole { li; ri; num; ws } ->
          let first, rest = Whitespace.split ws in
          ({ value = Hole { li; ri; num; ws = first }; loc }, rest))

(* Helper functions for constructing notation trees *)

let singleton tok br = TokMap.singleton tok (br, `Noss)
let oflist brs = TokMap.of_list (List.map (fun (tok, x) -> (tok, (x, `Noss))) brs)
let op tok x = Inner { empty_branch with ops = TokMap.singleton tok (x, `Noss) }

let ops toks =
  Inner { empty_branch with ops = TokMap.of_list (List.map (fun (k, x) -> (k, (x, `Noss))) toks) }

let term tok x = Inner { empty_branch with term = Some (TokMap.singleton tok (x, `Noss)) }

let terms toks =
  Inner
    {
      empty_branch with
      term = Some (TokMap.of_list (List.map (fun (k, x) -> (k, (x, `Noss))) toks));
    }

let field x = Inner { empty_branch with field = Some x }
let of_entry e = Inner { empty_branch with ops = e }

let done_open n =
  let _, tight, _ = fixprops (snd n) in
  Done_open (No.le_refl tight, n)

(* Similar, but for "entries". *)
let eop tok x = TokMap.singleton tok (x, `Noss)
let eops toks = TokMap.of_list (List.map (fun (k, x) -> (k, (x, `Noss))) toks)
let empty_entry = TokMap.empty

(* Merging notation trees. *)

let merge_opt : type a b. (a -> b -> a) -> (b -> a) -> a option -> b option -> a option =
 fun m l x y ->
  match (x, y) with
  | None, None -> None
  | Some x, None -> Some x
  | None, Some y -> Some (l y)
  | Some x, Some y -> Some (m x y)

let rec lower_tree : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t2, s2) tree -> (t1, s1) tree =
 fun sub xs ->
  match xs with
  | Inner br -> Inner (lower_branch sub br)
  | Done_open (lt, n) -> Done_open (No.Interval.subset_contains sub lt, n)
  | Done_closed n -> Done_closed n
  | Lazy tr -> Lazy (lazy (lower_tree sub (Lazy.force tr)))
  | Ambiguity strs -> Ambiguity strs
  | Ambiguity_closed strs -> Ambiguity_closed strs

and lower_branch : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t2, s2) branch -> (t1, s1) branch =
 fun sub { ops; field; term } ->
  {
    ops = TokMap.map (fun (xs, ss) -> (lower_tree sub xs, ss)) ops;
    field = Option.map (lower_tree sub) field;
    term = Option.map (TokMap.map (fun (xs, ss) -> (lower_tree sub xs, ss))) term;
  }

let lower : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t2, s2) entry -> (t1, s1) entry =
 fun sub map -> TokMap.map (fun (xs, ss) -> (lower_tree sub xs, ss)) map

let rec names : type t s. (t, s) tree -> string list = function
  | Inner { ops; field; term } ->
      Option.fold ~none:[] ~some:names field
      @ names_tmap ops
      @ Option.fold ~none:[] ~some:names_tmap term
  | Done_open (_, n) -> [ (find n).name ]
  | Done_closed n -> [ (find n).name ]
  | Lazy _ -> []
  | Ambiguity strs | Ambiguity_closed strs -> strs

and names_tmap : type t s. (t, s) tokmap -> string list =
 fun trees -> TokMap.fold (fun _ (t, _) xs -> names t @ xs) trees []

(* We are not maximally tolerant of ambiguity in notations.  In principle, it is possible to have one mixfix notation that is a strict initial segment of the other, like the "if_then_" and "if_then_else_" discussed in Danielsson-Norell.  However, it seems very hard to parse such a setup without a significant amount of backtracking, so we forbid it.  This is detected here at merge time.  Note that this includes the case of two notations that are identical.  (It is, of course, possible to have two notations that start out the same but then diverge, like _⊢_⦂_ and _⊢_type -- this is the whole point of merging trees.)  However, because this could happen accidentally when importing many notations from different libraries, we don't raise the error unless it actually comes up during parsing, by wrapping it in a lazy branch of the notation tree. *)
let rec merge_tree : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t1, s1) tree -> (t2, s2) tree -> (t1, s1) tree =
 fun sub xs ys ->
  match (xs, ys) with
  | Lazy (lazy xs), _ -> merge_tree sub xs ys
  | _, Lazy (lazy ys) -> merge_tree sub xs ys
  | Inner xb, Inner yb -> Inner (merge_branch sub xb yb)
  (* As a special case, if a left-open notation and one or more left-closed notations have exactly the same tree, we resolve the ambiguity in favor of the left-open one. *)
  | Done_open _, Done_closed _ | Done_open _, Ambiguity_closed _ -> xs
  | Done_closed _, Done_open _ | Ambiguity_closed _, Done_open _ -> lower_tree sub ys
  | Done_closed _, Done_closed _
  | Done_closed _, Ambiguity_closed _
  | Ambiguity_closed _, Done_closed _
  | Ambiguity_closed _, Ambiguity_closed _ -> Ambiguity_closed (names xs @ names ys)
  | _ -> Ambiguity (names xs @ names ys)

and merge_tmap : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t1, s1) tokmap -> (t2, s2) tokmap -> (t1, s1) tokmap =
 fun sub x y ->
  TokMap.fold
    (fun k (yb, ssy) ->
      TokMap.update k (function
        | None -> Some (lower_tree sub yb, ssy)
        | Some (xb, ssx) when ssx = ssy -> Some (merge_tree sub xb yb, ssy)
        (* If the two notations disagree about whether superscripts are allowed, it is an ambiguity. *)
        | Some (xb, _) -> Some (Ambiguity (names xb @ names yb), ssy)))
    y x

and merge_branch : type t1 s1 t2 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t1, s1) branch -> (t2, s2) branch -> (t1, s1) branch =
 fun sub x y ->
  let ops = merge_tmap sub x.ops y.ops in
  let field = merge_opt (merge_tree sub) (lower_tree sub) x.field y.field in
  let term =
    merge_opt (merge_tmap sub) (TokMap.map (fun (xs, ss) -> (lower_tree sub xs, ss))) x.term y.term
  in
  { ops; field; term }

let merge : type t1 t2 s1 s2.
    (t2, s2, t1, s1) No.Interval.subset -> (t1, s1) entry -> (t2, s2) entry -> (t1, s1) entry =
 fun sub xs ys -> merge_tmap sub xs ys
