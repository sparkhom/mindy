module: d2c-gnu

//========================================================================
//
// Utility Functions and Variables
//
//========================================================================

define variable $dig-debug :: <boolean> = #f;
define variable *interactive-mode* :: <boolean> = #f;

// This function should be added to the string-extensions library.  It
// simply checks whether the first string is an initial subsequence of
// the second -- simple, but very common.
//
define method is-prefix?
    (short :: <string>, long :: <string>, #key empty-ok? :: <boolean> = #f) 
 => (result :: <boolean>);
  case 
    (short.size == 0) => empty-ok?;
    (short.size > long.size) => #f;
    otherwise =>
      block (return)
	for (c1 in short, c2 in long)
	  if (c1 ~== c2) return(#f) end if;
	end for;
	#t;
      end block;
  end case;
end method is-prefix?;

// This function will shortly be deprecated in favor of "regexp-matches"
//
define constant *match-strings-table* :: <table> = make(<table>);
define method match-strings
    (big :: <string>, matcher :: <string>, #rest positions)
  let (func) = element(*match-strings-table*, matcher, default: #f);
  if (~func)
    func := *match-strings-table*[matcher] := make-regexp-positioner(matcher);
  end if;
  apply(match-strings, big, func, positions);
end method match-strings;

// This function will shortly be deprecated in favor of "regexp-matches"
//
define method match-strings
    (big :: <string>, matcher :: <function>, #rest positions)
 => (#rest result :: false-or(<string>));
  let (#rest results) = matcher(big);
  let return = make(<vector>, size: positions.size);
  for (raw-pos in positions, index from 0)
    let pos = raw-pos * 2;
    if (element(results, pos, default: #f))
      return[index]
	:= copy-sequence(big, start: results[pos], end: results[pos + 1]);
    else
      return[index] := #f;
    end if;
  end for;
  apply(values, return);
end method match-strings;



//========================================================================
//
// GDB and user communication routines.
//
//========================================================================

// Send a line of output to the user and be sure that he gets it.  The
// args are the same as those of "format".
//
define inline method send-user-response
    (template :: <byte-string>, #rest args);
  apply(format, *standard-output*, template, args);
  force-output(*standard-output*);
end method send-user-response;

// Read a line from the user and split it up into a "command" and an
// "argument" string.  Both wil be #f if the user enters an empty
// line.
define method receive-user-command ()
 => (command :: false-or(<byte-string>), args :: false-or(<byte-string>));
  let line = read-line(*standard-input*);
  if (line.empty?)
    #f;
  else
    let (comm, args) = split("[ \t]+", line, count: 2);
    values(comm | line, args | "");
  end if;
end method receive-user-command;

// Streams which will be used to communicate with the GDB subprocess.
// These values are rewritten by open-gdb-process
//
define variable $to-gdb :: <stream> = *standard-output*;
define variable $from-gdb :: <stream> = *standard-input*;

// Create a new gdb subprocess and set the I/O variables
// appropriately.  Mostly just calls "fd-exec" which has been
// specialized for GDB.
//
define method open-gdb-process (#rest args) => ();
  let (to-fd, from-fd) = fd-exec(apply(join, " ", "gdb", args));
  $to-gdb := make(<fd-stream>, direction: #"output", fd: to-fd);
  $from-gdb := make(<fd-stream>, direction: #"input", fd: from-fd);
end method open-gdb-process;

// Find out if we are at the GDB prompt.  We must magically match this
// in order to determine what consitutes the output of a single GDB
// command.
//
define variable *gdb-prompt* = "(gdb) ";

define method at-prompt?
    (data :: <vector>, prompt :: <byte-string>) => (result :: <boolean>);
  block (return)
    for (data-index from data.size - 1 to 0 by -1,
	 prompt-index from prompt.size - 1 to 0 by -1)
      if (data[data-index] ~== prompt[prompt-index]) return(#f) end if;
    finally
      prompt-index < 0;
    end for;
  end block;
end method at-prompt?;

// A simple shortcut routine to send a string to GDB and be sure that
// it is received.  The args follow those of format.  Note that the
// output must be terminated with a newline in order for GDB to
// process it.
//
define inline method send-gdb-command
    (template :: <byte-string>, #rest args)
  if ($dig-debug)
    apply(format, *standard-output*, template, args);
    force-output(*standard-output*);
  end if;
    
  apply(format, $to-gdb, template, args);
  force-output($to-gdb);
end method send-gdb-command;

// This incredibly messy function attempts to retrieve data from the
// GDB process, while accounting for the fact that the user process
// may pause for user input.  The "simple" path followed when in
// "interactive" mode is much more reliable.
//
// The "echo:" keyword is used to control whether the user sees any of the
// output.  
//
define method receive-gdb-response
    (#key echo = #t, interactive = (echo & *interactive-mode*))
 => (result :: <byte-string>);
  let input = make(<stretchy-vector>);
  let line = make(<stretchy-vector>);
  block (return)
    if (interactive)
      // Lots of hairy stuff to handle the fact that there are two
      // different processes waiting for input from the same source.
      // This works only as long as the user does no type-ahead.
      while (#t)
	while (stream-input-available?($from-gdb))
	  let char = read-element($from-gdb);
	  if ($dig-debug)
	    format(*standard-output*, "!%c", char);
	    force-output(*standard-output*);
	  end if;
	  add!(line, char);
	  if (echo)
	    write-element(*standard-output*, char);
	    force-output(*standard-output*);
	  end if;
	  if (char == '\n')
	    let str = as(<byte-string>, line);
	    add!(input, str);
	    line.size := 0;
	  end if;
	  if (at-prompt?(line, *gdb-prompt*))
	    line.size := line.size - *gdb-prompt*.size;
	    let str = as(<byte-string>, line);
	    if (echo)
	      write(*standard-output*, str);
	      force-output(*standard-output*);
	    end if;
	    add!(input, str);
	    let result = apply(concatenate, input);
	    if ($dig-debug)
	      format(*standard-output*, "+++\n%s+++\n", result);
	      force-output(*standard-output*);
	    end if;
	    return(result);
	  end if;
	end while;
	while (stream-input-available?(*standard-input*))
	  write-element($to-gdb, read-element(*standard-input*));
	end while;
	force-output($to-gdb);
#if (~mindy)
	call-out("sleep", void:, int: 0);
#endif
      end while;
    else
      // The simple case -- assume the user process isn't going to
      // wait for any input.
      while (#t)
	let char = read-element($from-gdb);
	if ($dig-debug)
	  format(*standard-output*, "!%c", char);
	  force-output(*standard-output*);
	end if;
	add!(line, char);
	if (echo)
	  write-element(*standard-output*, char);
	  force-output(*standard-output*);
	end if;
	if (char == '\n')
	  let str = as(<byte-string>, line);
	  add!(input, str);
	  line.size := 0;
	end if;
	if (at-prompt?(line, *gdb-prompt*))
	  line.size := line.size - *gdb-prompt*.size;
	  let str = as(<byte-string>, line);
	  if (echo)
	    write(*standard-output*, str);
	    force-output(*standard-output*);
	  end if;
	  add!(input, str);
	  let result = apply(concatenate, input);
	  if ($dig-debug)
	    format(*standard-output*, "+++\n%s+++\n", result);
	    force-output(*standard-output*);
	  end if;
	  return(result);
	end if;
      end while;
    end if;
  end block;
end method receive-gdb-response;

// Executes a "private" (i.e. non-echoed) gdb-command, and returns the
// output of this command.
//
define method do-gdb-command
    (template :: <string>, #rest args) => (output :: <string>);
  apply(send-gdb-command, template, args);
  receive-gdb-response(echo: #f);
end method do-gdb-command;


//========================================================================
//  Invoking Dylan functions (in the process being debugged)
//========================================================================

// Check the output from a function call to find out whether the function
// dumped core.  If so, call a designated error signaller and return the the
// point at which we called the function.  This code depends on the
// magically defined breakpoint in the error handler.
//
define method check-seg-fault (str :: <string>) => (result :: <boolean>);
  if (match-strings(str, "Program received signal SIGSEGV", 0))
    do-gdb-command("set dylan_seg_fault_error_main(orig_sp)\n");
    do-gdb-command("continue\n");
    send-user-response("Program received signal SIGSEGV -- giving up.\n");
    #t;
  end if;
end method check-seg-fault;

// Applies an appropriate printer for the value depending upon it's type.
// Will sometimes call in to the user process for its domain specific
// expertise.
//
define method print-any-value (line)
  let value = do-gdb-command("print %s\n", line);
  let (idstr, heapptr1, heapptr2, extra)
    = match-strings(value,
		    "((.|\n)*)(\\$[0-9]+) = "
		      "(\\(struct heapobj \\*\\) (.*)|\\{heapptr = ([^,]+))",
		    3, 5, 6, 1);
  case
    (heapptr1) =>
      let result = do-gdb-command("set gdb_print_heapobj(%s)\n", idstr);
      unless (check-seg-fault(result))
	send-user-response("%s%s = %s", extra, idstr, result);
      end unless;
    (heapptr2) =>
      let result = do-gdb-command("set gdb_print_genobj(%s)\n", idstr);
      unless (check-seg-fault(result))
	send-user-response("%s%s = %s", extra, idstr, result);
      end unless;
    otherwise =>
      send-user-response(value);
  end case;
end method print-any-value;

// Apply the given Dylan function to a list of arguments (which are
// currently passed as a comma-separated list of expressions).  Each
// argument should be a simple C expression -- no Dylan sub-invocations are
// permitted.
//
// RUNTIME DEPENDENCY: This depends upon the several magic runtime functions
// -- "gdb_invoke_function", "string_arg", "desc_arg", "heap_arg", and
// "end_arg" -- operating in a known predictable manner.  "string_arg" will
// not work unless the "/usr/lib/end.o" is linked into the executable.
// (This should be ensured by "main.dylan".
//
define method invoke-dylan-function
    (function :: <string>, arglist :: <string>) => (result-count :: <integer>);
  let arg-pushers = make(<stretchy-vector>);
  let (count, error) = 
    block (return)
      local
	method add-pusher (arg :: <string>) => ();
	  let expr = arg;
	  let type = element(*var-types*, arg, default: #f);
	  unless (type)
	    let (tag, tag-type) = expr-token(arg);
	    expr := tag;
	    type := tag-type;
	  end unless;
	  select (type)
	    #"string" =>
	      add!(arg-pushers, concatenate("string_arg(", expr, ")"));
	    #"descriptor" =>
	      add!(arg-pushers, concatenate("desc_arg(", expr, ")"));
	    #"heap-object" =>
	      add!(arg-pushers, concatenate("heap_arg(", expr, ")"));
	    #"other" =>
	      add!(arg-pushers, concatenate("int_arg(", expr, ")"));
	    otherwise =>
	      return(format-to-string("Bad argument: %s", arg));
	  end select;
	end method add-pusher;
      unless (function) return("Invalid invocation") end unless;
      add-pusher(function);
      let (#rest args) = split(",[ \t]*", arglist);
      for (arg in args)
	let (keyarg, real-arg)
	  = match-strings(arg, "([a-zA-Z0-9]+_sym_[a-zA-Z0-9_]+)?(.*)", 1, 2);
	if (keyarg)
	  add-pusher(keyarg);
	end if;
	add-pusher(real-arg);
      end for;
      for (command in arg-pushers)
	do-gdb-command("set %s\n", command);
      end for;
      let value
	= do-gdb-command("p gdb_invoke_function"
			   "((descriptor_t)dylan_apply_safely, %d)\n",
			 size(arg-pushers));
      if (check-seg-fault(value))
	0;
      else
	let (extra, intarg)
	  = match-strings(value,
			  "^((.|\n)*)(\\$[0-9]+) = ([0-9]+)",
			  1, 4);
	unless (intarg)
	  let result = do-gdb-command("continue\n");
	  return(0, match-strings(result, "Continuing\\.\n(.*)\n", 1));
	end unless;
	send-user-response("%s", extra);
	values(string-to-integer(intarg), #f);
      end if;
    end block;
  if (error) send-user-response("%s\n", error) end if;
  count;
end method invoke-dylan-function;

// This convenience function grabs the first return value from the last
// function invocation.
//
// RUNTIME DEPENDENCY: This depends upon the magic runtime function
// "gdb_invoke_function" operating in a known predictable manner.
//
define method dylan-function-result
    (function :: <string>, arglist :: <string>) => (result-tag :: <string>);
  let count = invoke-dylan-function(function, arglist);
  if (count == 0)
    "dylan_false";
  else
    expr-token("gdb_result_stack[0]");
  end if;
end method dylan-function-result;


//========================================================================
// Translating Dylan variable names
//
// COMPILER DEPENDENCY -- All routines in this section depend upon an
// intimate knowledge of the compiler's name-mangling strategies.  Any
// change in that code which is not reflected here will cause many things to
// immediately stop working.
//========================================================================

// The following two routines are lifted (and adapted) straight out of the
// D2C compiler.  Look to the compiler for an explanation of what is going
// on.
//
define constant c-prefix-transform :: <vector>
  = begin
      let map = make(<byte-string>, size: 256, fill: 'X');
      local
	method fill-range
	    (start :: <character>, stop :: <character>, xform :: <function>)
	    => ();
	  for (i from as(<integer>, start) to as(<integer>, stop))
	    map[i] := xform(as(<character>, i));
	  end for;
	end method fill-range;
      map[as(<integer>, ' ')] := '_';
      map[as(<integer>, '!')] := 'D';
      map[as(<integer>, '$')] := '_';
      map[as(<integer>, '%')] := '_';
      map[as(<integer>, '&')] := 'O';
      map[as(<integer>, '*')] := 'O';
      map[as(<integer>, '+')] := 'O';
      map[as(<integer>, '-')] := '_';
      map[as(<integer>, '/')] := 'O';
      fill-range('0', '9', identity);
      map[as(<integer>, '<')] := 'O';
      map[as(<integer>, '=')] := 'O';
      map[as(<integer>, '>')] := 'O';
      map[as(<integer>, '?')] := 'P';
      fill-range('A', 'Z', as-lowercase);
      map[as(<integer>, '^')] := 'O';
      map[as(<integer>, '_')] := '_';
      fill-range('a', 'z', identity);
      map[as(<integer>, '|')] := 'O';
      map[as(<integer>, '~')] := 'O';
      map;
    end;

define method c-prefix (description :: <string>) => (result :: <string>);
  if (description.empty?)
    description;
  else
    let start = 0;
    for (i :: <integer> from start below description.size,
	 until: description[i] == ' ')
    finally
      let (first, last, offset, result)
	= if (i > start & description[start] == '<'
		& description[i - 1] == '>')
	    values(start + 1, i - 1, 4, 
		   map-into(make(<byte-string>, size: i - start + 2),
			    identity, "cls_"));
	  elseif (description[i - 1] == ':')
	    values(start, i - 1, 4, 
		   map-into(make(<byte-string>, size: i - start + 3),
			    identity, "sym_"));
	  else
	    values(start, i, 0, make(<byte-string>, size: i - start));
	  end if;
      for (j :: <integer> from offset, i :: <integer> from first below last)
	result[j] := c-prefix-transform[as(<integer>, description[i])];
      end for;
      result;
    end for;
  end if;
end method c-prefix;

define constant <variable-types> = one-of(#"string", #"heap-object",
					  #"descriptor", #"other");

define variable *cached-locals-vars* :: false-or(<string>) = #f;

define constant *var-table* :: <string-table> = make(<string-table>);
define constant *var-types* :: <string-table> = make(<string-table>);

// The following routines all attempt to interpret a name in a single
// specialized domain.  If the succeed, they will potentially mangle the
// name into a form more meaningful to GDB and note information about the
// variable's type.  If not, they will simply return #f.

// Check whether the variable is defined as a local.  We must do this first,
// since local variables will shadow globals.  Local variables are subject
// to change, so we must not let them get into the lookup caches.
//
// Non-local dependency -- We keep a "locals-only" cache to speed up this
// routine.  It must be flushed before every command, since we don't know
// which commands may change our location in the user program.
//
define method find-local-variable
    (c-name :: <string>)
 => (name :: false-or(<string>), type :: false-or(<variable-types>));
  let locals  = (*cached-locals-vars* |
		   (*cached-locals-vars*
		      := concatenate(do-gdb-command("info local\n"),
				     do-gdb-command("info args\n"))));
  let match-start :: false-or(<integer>) = substring-position(locals, c-name);
  while (match-start
	   & element(locals, match-start - 1, default: '\n') ~== '\n')
    match-start := substring-position(locals, c-name, start: match-start + 1);
  end while;
  if (match-start)
    let (found, dummy, rest-start, rest-end)
      = regexp-position(locals, "^ = (.*)", start: match-start + c-name.size);
    if (found)
      let rest = copy-sequence(locals, start: rest-start, end: rest-end);
      let (stringarg, descarg, heaparg)
	= match-strings(rest,
			"^((\"[^\"]+\")"
			  "|\\{heapptr = ([^,]+)"
			  "|\\(struct heapobj \\*\\) (.*))",
			2, 3, 5);
      let type = case
		   stringarg => #"string";
		   descarg => #"descriptor";
		   heaparg => #"heap-object";
		   otherwise => #"other";
		 end case;
      values(c-name, type);
    end if;
  end if;
end method find-local-variable;

// Check to see if the given variable is a regular C variable.  Note that
// such variables may still hold Dylan objects.
//
define method find-global-variable
    (name :: <string>) => (c-name :: false-or(<string>));
  let response = do-gdb-command("info var ^%s$\n", name);
  if (response)
    let (found, next, type-start, type-end, first, last)
      = regexp-position(response, "(.* \\*?)([^ ]+)[[;]\n");
    if (found)
      let type-string = copy-sequence(response,
				      start: type-start, end: type-end);
      let type = select (type-string by \=)
		   "descriptor_t " => #"descriptor";
		   "heapptr_t " => #"heap-object:";
		   "char *" => #"string";
		   otherwise => #"other";
		 end select;
      *var-types*[name] := type;
      *var-table*[name] := name;
    end if;
  end if;
end method find-global-variable;

// Check to see if the given variable is a Dylan name which can be
// translated into a regular C variable name.  If so, we actually return the
// translated value.  Since the same name may appear in several modules, we
// can potentially return several values.
//
// COMPILER DEPENDENCY -- We incorporate knowledge about how the compiler
// builds names.  If the compiler changes, then so must we.
//
define method find-dylan-variable-list
    (dylan-name :: <string>) => (#rest c-names :: <string>);
  let search-string = c-prefix(dylan-name);
  let response = do-gdb-command("info var ^[a-zA-Z0-9]*_%s$\n", search-string);
  local method do-search (pos :: <integer>, res :: <list>) => (res :: <list>);
	  let (found, next, type-start, type-end, first, last)
	    = regexp-position(response, "(.*) ([^ ]+)[[;]\n", start: pos);
	  if (found)
	    let name = copy-sequence(response, start: first, end: last);
	    let type-string = copy-sequence(response,
					    start: type-start, end: type-end);
	    let type = select (type-string by \=)
			 "descriptor_t" => #"descriptor";
			 "heapptr_t" => #"heap-object:";
			 // I don't think that strings will ever occur.
			 otherwise => #"other";
		       end select;
	    *var-types*[name] := type;
	    do-search(next, pair(name, res));
	  else
	    res;
	  end if;
	end method do-search;
  apply(values, do-search(0, #()));
end method find-dylan-variable-list;

// If find-dylan-variable-list above returns several values, we must go to
// the user to find out which is the correct one.  This routines does this
// for us.
//
define method find-dylan-variable
    (dylan-name :: <string>) => (result :: false-or(<string>));
  let (#rest vars) = find-dylan-variable-list(dylan-name);
  select (vars.size)
    0 => #f;
    1 => *var-table*[dylan-name] := vars.first;
    otherwise =>
      send-user-response("There are several possible translations of %s:\n",
			 dylan-name);
      for (var in vars, index from 1)
	send-user-response("  %2d: %s\n", index, var);
      end for;
      local method get-response () => (result :: <string>);
	      send-user-response("Which one? ");
	      let line = read-line(*standard-input*);
	      block ()
		let index = string-to-integer(line);
		if (index > 0 & index <= vars.size)
		  *var-table*[dylan-name] := vars[index - 1];
		else
		  get-response();
		end if;
	      exception (<error>)
		get-response();
	      end block;
	    end method get-response;
      get-response();
  end select;
end method find-dylan-variable;

// Look for a variable in all of the known specialized domains.  If we can't
// find it in any of them, than it must not be a variable.
//
// Exception: "GDB variables" (i.e. "$23") are not recognized by this
// routine.  This will result in them being passed to GDB verbatim, which is
// what we want.
//
define method select-any-variable
    (name :: <string>) => (result :: false-or(<string>));
  if (match-strings(name, "^[=-+/*]$|^\\$[0-9]+$", 0))
    #f;
  else
    element(*var-table*, name, default: #f)
      | find-local-variable(name)
      | find-global-variable(name)
      | find-dylan-variable(name);
  end if;
end method select-any-variable;

// Finds all potential variable names in a string and attempts to translate
// Dylan variable names into regular C names.
//
define method translate-arg-vars (arg :: <string>)
  local method try-one-var (string :: <string>, start :: <integer>)
	  let (first, last)
	    = regexp-position(string,
			      "[-a-zA-Z*/+_?=~&<>|^@]"
				"[-0-9a-zA-Z*/+_?=~$&<>|^@]*:?",
			      start: start);
	  if (~first)
	    string;
	  else
	    let name = select-any-variable(copy-sequence(string, start: first, 
							 end: last));
	    if (name)
	      try-one-var(replace-subsequence!(string, name, start: first,
					       end: last), first + name.size);
	    else
	      try-one-var(string, last);
	    end if;
	  end if;
	end method try-one-var;
  try-one-var(arg, 0);
end method translate-arg-vars;



//========================================================================
// Evaluating arbitrary Dylan & C expressions
//========================================================================

// Evaluates the given string as a C expression and returns a GDB variable
// name (i.e. "$23") and an indication of the variable's type.
//
define method expr-token (expr :: <string>)
 => (result :: <string>, type :: false-or(<variable-types>));
  let result = do-gdb-command("print %s\n", expr);
  let (tag, intarg, stringarg, descarg, heaparg, extra)
    = match-strings(result,
		    "^((.|\n)*)(\\$[0-9]+) = (([0-9]+)|(\"[^\"]+\")"
		      "|\\{heapptr = ([^,]+)"
		      "|\\(struct heapobj \\*\\) (.*))?",
		    3, 5, 6, 7, 8, 1);
  if (tag)
    let type = *var-types*[tag] := case
				     stringarg => #"string";
				     descarg => #"descriptor";
				     heaparg => #"heap-object";
				     otherwise => #"other";
				   end case;
    send-user-response(extra);
    values(tag, type);
  else
    values(expr, #f);
  end if;
end method expr-token;

// Returns #t iff the given variable contains a "Dylan object"
// (i.e. something in the standard Heap or General representation).
define method dylan-object? (name :: <string>) => (result :: <boolean>);
  let (type) = element(*var-types*, name, default: #f);
  unless (type)
    let (tag, tag-type) = expr-token(name);
    type := *var-types*[name] := tag-type;
  end unless;
  type == #"descriptor" | type == #"heap-object";
end method dylan-object?;
    
// Converts nested strings and function calls into GDB variables (calling
// routines as necessary).  This has the effect of decomposing sets of
// nested function calls into a sequence of calls which can be handled by
// "invoke-dylan-function".
//
define method transform-expression (expr :: <string>) => (result :: <string>);
  local method replace-quotes (str)
	  let (match) = match-strings(str, "\"([^\"\\\\]|\\\\.)*\"", 0);
	  if (match)
	    let newstr = substring-replace(str, match, match.expr-token);
	    replace-quotes(newstr);
	  else
	    str;
	  end if;
	end method replace-quotes;
  local method replace-functions (str)
	  let (match, fun, args)
	    = match-strings(str, "([a-zA-Z0-9_]+)[ \t]*\\(([^()]+)\\)",
			    0, 1, 2);
	  if (~match)
	    str;
	  elseif (fun.dylan-object?)
	    replace-functions
	      (substring-replace(str, match,
				   dylan-function-result(fun, args)));
	  else
	    replace-functions
	      (substring-replace(str, match, match.expr-token));
	  end if;
	end method replace-functions;
  replace-functions(translate-arg-vars(replace-quotes(expr)));
end method transform-expression;


//========================================================================
// Generic function breakpoints
//========================================================================

// Performs really hairy magic in order to find the names of each of the
// functions which serve as "generic entries" for the given generic function
// object.
//
// COMPILER DEPENDCY -- we depend upon knowing how function entries are
// named, and how generic function objects are named.
//
// RUNTIME DEPENDENCY -- we depend up the routine "generic-entry" which is
// defined, but not exported, by the dylan library (in "func.dylan").
//
define method generic-function-generic-entries
    (fun :: <string>) => (#rest entries :: <string>);
  block (return)
    let funs = dylan-function-result("dylan_generic_function_methods", fun);
    if (funs = "dylan_false") return() end if;

    let entries = dylan-function-result("dylan_map",
					concatenate("dylan_generic_entry",
						    ", ", funs));
    if (entries = "dylan_false") return() end if;

    let size-str = do-gdb-command("set gdb_print_genobj(%s)\n",
				  dylan-function-result("dylan_size",
							entries));
    let size = string-to-integer(match-strings(size-str, "[0-9]+", 0));
    let results = make(<stretchy-vector>);
    for (i from 0 below size)
      let entry = dylan-function-result("dylan_element",
					format-to-string("%s, %d",
							 entries, i));
      let instr = do-gdb-command("x/i %s.dataword.ptr\n", entry);
      let name = match-strings(instr, "<([^>]+)>", 1);
      add!(results, name);
    end for;
    apply(values, results);
  end block;
end method generic-function-generic-entries;

// Use nasty heuristics and mild voodoo to figure out all of the "main
// entries" which exist for the given generic function.  Don't try to figure
// out the perverted logic -- just be happy when it works and scream to
// "rgs@cs.cmu.edu" when it doesn't.
//
define method set-generic-breakpoints (fun :: <string>) => ();
  let (#rest entries) = generic-function-generic-entries(fun);
  let entry-table = make(<string-table>);
  for (entry in entries)
    let str = match-strings(entry, "^(.*)_generic(_[0-9]+)?", 1);
    unless (key-exists?(entry-table, str))
      entry-table[str] := #t;
      let result = do-gdb-command("info fun ^%s_main\n", str);
      local method find-funs (pos :: <integer>)
	      let (found, next, first, last)
		= regexp-position(result, "([a-zA-Z_][a-zA-Z0-9_]*)\\(",
				  start: pos);
	      if (found)
		let proc = copy-sequence(result, start: first, end: last);
		send-user-response(do-gdb-command("break %s\n", proc));
		find-funs(next);
	      end if;
	    end method find-funs;
      find-funs(0);
    end unless;
  end for;
end method set-generic-breakpoints;
 
// Sets simple breakpoints in C functions or on each possible main entry for
// Dylan generic functions.
//
define method set-any-breakpoints (fun :: <string>) => ();
  let real-name = select-any-variable(fun);
  if (real-name & real-name.dylan-object?)
    set-generic-breakpoints(real-name);
  else
    send-user-response(do-gdb-command("break %s\n", real-name | fun));
  end if;
end method set-any-breakpoints;


//========================================================================
// Command processing
//========================================================================

define constant *command-table* :: <string-table> = make(<string-table>);

define method dispatch-command (command :: <string>, line :: <string>)
  let proc = element(*command-table*, command, default: #f);
  if (proc)
    proc(line);
    send-user-response("%s", *gdb-prompt*);
  else
    let count :: <integer> = 0;
    let result :: false-or(<string>) = #f;
    for (str in *command-table*.key-sequence)
      if (is-prefix?(command, str))
	count := count + 1;
	result := str;
      end if;
    end for;
    select (count)
      0 =>
	send-user-response("%s", do-gdb-command("%s %s\n", command, line));
//	invoke-dylan-function("dylan_condition_force_output",
//			      "dylan_Owarning_outputO");
	send-user-response("%s", *gdb-prompt*);
      1 =>
	*command-table*[result](line);
//	invoke-dylan-function("dylan_condition_force_output",
//			      "dylan_Owarning_outputO");
	send-user-response("%s", *gdb-prompt*);
      otherwise =>
	send-user-response("Ambiguous command: %s\n%s",
			   command, *gdb-prompt*);
    end select;
  end if;
end method dispatch-command;

#if (~mindy)
define macro dig-command-definer 
  { define dig-command ?name:token (?line:name)
      ?val:body
    end } 
    => {*command-table*[?name] 
          := method (?line :: <string>)
               ?val;
	     end method; }
end macro;
#endif


//========================================================================
// Commands
//======================================================================== 

define variable $exit-fun :: false-or(<function>) = #f;

#if (~mindy)
define dig-command "quit" (str)
  send-user-response("Bye!\n");
  $exit-fun();
end;

define dig-command "interactive" (line)
  case
    regexp-position(line, "^ *on *$") =>  *interactive-mode* := #t;
    regexp-position(line, "^ *off *$") => *interactive-mode* := #f;
    otherwise => *interactive-mode* := ~*interactive-mode*;
  end case;
  send-user-response("interactive mode %s\n",
		     if (*interactive-mode*) "on" else "off" end if)
end;

define dig-command "find" (line)
  let (name) = select-any-variable(line);
  if (name) send-user-response("%s\n", name) end if;
end;

define dig-command "print" (line)
  print-any-value(transform-expression(line));
end;

define dig-command "p" (line)
  print-any-value(transform-expression(line));
end;

define dig-command "pr" (line)
  print-any-value(transform-expression(line));
end;

define dig-command "run" (line)
  do-gdb-command("handle SIGSEGV nostop noprint pass\n");
  send-user-response("%s", do-gdb-command("run %s\n", line));
  do-gdb-command("handle SIGSEGV stop print nopass\n");
end;

define dig-command "prompt" (line)
  if (line.last ~= ' ') line := add!(line, ' ') end if;
  *gdb-prompt* := line;
  do-gdb-command("set prompt %s\n", line);
end;

define dig-command "break" (line)
  set-any-breakpoints(line);
end;

#else

*command-table*["print"] := compose(print-any-value, transform-expression);
*command-table*["break"] := set-any-breakpoints;
*command-table*["quit"] := method (line) $exit-fun() end method;

#endif


//========================================================================
// The actual program
//========================================================================

define variable $previous-command = "print";
define variable $previous-args = "\"No last command!\"";

define method command-loop () => ();
  block (exit-prog)
    $exit-fun := exit-prog;
    while (#t)
      let (command, args) = receive-user-command();
      if (command)
	dispatch-command(command, args);
	$previous-command := command;
	$previous-args := args;
      else
	dispatch-command($previous-command, $previous-args);
      end if;
      *cached-locals-vars* := #f;
    end while;
  end block;
end method command-loop;

#if (mindy)
define method main (prog-name :: <string>, #rest args);
  let raw-args = args;
  let args = make(<stretchy-vector>);
  for (i from 0 below raw-args.size)
    if (raw-args[i] = "-d")
      $dig-debug := #t;
    else
      add!(args, raw-args[i])
    end if;
  end for;
  apply(open-gdb-process, args);

  receive-gdb-response();
  do-gdb-command("break dylan_error_main_2\n");
  command-loop();
end method main;
#else
define method %main (argc :: <integer>, argv :: <object>)
  let raw-args = as(<arg-vector>, argv);
  let args = make(<stretchy-vector>);
  for (i from 1 below argc)
    if (raw-args[i] = "-d")
      $dig-debug := #t;
    else
      add!(args, raw-args[i])
    end if;
  end for;
  apply(open-gdb-process, args);

  receive-gdb-response();
  do-gdb-command("break dylan_error_main_2\n");
  command-loop();
end method %main;
#endif