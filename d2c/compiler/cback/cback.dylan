module: cback
rcs-header: $Header: /home/housel/work/rcs/gd/src/d2c/compiler/cback/cback.dylan,v 1.53 1995/05/29 20:57:17 wlott Exp $
copyright: Copyright (c) 1995  Carnegie Mellon University
	   All rights reserved.

define constant $indentation-step = 4;


// Indenting streams.

define class <indenting-stream> (<stream>)
  slot is-target :: <stream>, required-init-keyword: target:;
  slot is-buffer :: <buffer>, init-function: curry(make, <buffer>);
  slot is-after-newline? :: <boolean>, init-value: #t;
  slot is-column :: <fixed-integer>, init-value: 0;
  slot is-indentation :: <fixed-integer>,
    init-value: 0, init-keyword: indentation:;
end;

define method stream-extension-get-output-buffer (stream :: <indenting-stream>)
    => (buf :: <buffer>, next :: <buffer-index>, size :: <buffer-index>);
  values(stream.is-buffer, 0, stream.is-buffer.size);
end;

define constant $tab = as(<integer>, '\t');
define constant $space = as(<integer>, ' ');
define constant $newline = as(<integer>, '\n');

define method indenting-stream-spew-output
    (stream :: <indenting-stream>, stop :: <buffer-index>)
    => ();
  unless (zero?(stop))
    let (target-buffer, target-next, target-size)
      = get-output-buffer(stream.is-target);
    local
      method spew-n-chars (n, char)
	let available = target-size - target-next;
	while (available < n)
	  for (i from target-next below target-size)
	    target-buffer[i] := char;
	  end;
	  empty-output-buffer(stream.is-target, target-size);
	  target-next := 0;
	  n := n - available;
	  available := target-size;
	end;
	for (i from target-next below target-next + n)
	  target-buffer[i] := char;
	finally
	  target-next := i;
	end;
      end,
      method spew-char (char)
	if (target-next == target-size)
	  empty-output-buffer(stream.is-target, target-size);
	  target-next := 0;
	end;
	target-buffer[target-next] := char;
	target-next := target-next + 1;
      end;
    let buffer = stream.is-buffer;
    let column = stream.is-column;
    let after-newline? = stream.is-after-newline?;
    for (i from 0 below stop)
      let char = buffer[i];
      if (char == $newline)
	spew-char(char);
	column := 0;
	after-newline? := #t;
      elseif (char == $space)
	unless (after-newline?)
	  spew-char(char);
	end;
	column := column + 1;
      elseif (char == $tab)
	let old-column = column;
	column := ceiling/(column + 1, 8) * 8;
	unless (after-newline?)
	  spew-n-chars(column - old-column, $space);
	end;
      else
	if (after-newline?)
	  let (tabs, spaces) = floor/(stream.is-indentation + column, 8);
	  spew-n-chars(tabs, $tab);
	  spew-n-chars(spaces, $space);
	  after-newline? := #f;
	end;
	spew-char(char);
	column := column + 1;
      end;
    end;
    release-output-buffer(stream.is-target, target-next);
    stream.is-after-newline? := after-newline?;
    stream.is-column := column;
  end;
end;

define method stream-extension-release-output-buffer
    (stream :: <indenting-stream>, next :: <buffer-index>)
    => ();
  indenting-stream-spew-output(stream, next);
end;

define method stream-extension-empty-output-buffer
    (stream :: <indenting-stream>, stop :: <buffer-index>)
    => ();
  indenting-stream-spew-output(stream, stop);
end;

define method stream-extension-force-secondary-buffers
    (stream :: <indenting-stream>)
    => ();
  force-secondary-buffers(stream.is-target);
end;  

define method stream-extension-synchronize (stream :: <indenting-stream>)
    => ();
  synchronize(stream.is-target);
end;

define method close (stream :: <indenting-stream>) => ();
  force-output(stream);
end;

define method indent (stream :: <indenting-stream>, delta :: <fixed-integer>)
    => ();
  stream.is-indentation := stream.is-indentation + delta;
end;

define constant make-indenting-string-stream
  = method (#rest keys)
	=> res :: <indenting-stream>;
      apply(make, <indenting-stream>,
	    target: make(<byte-string-output-stream>),
	    keys);
    end;

define method string-output-stream-string (stream :: <indenting-stream>)
    => res :: <byte-string>;
  stream.is-target.string-output-stream-string;
end;


// Output file state

define class <output-info> (<object>)
  //
  // Stream for the header file.
  slot output-info-header-stream :: <stream>,
    required-init-keyword: header-stream:;
  //
  slot output-info-body-stream :: <stream>,
    required-init-keyword: body-stream:;
  //
  slot output-info-vars-stream :: <stream>,
    init-function: curry(make-indenting-string-stream,
			 indentation: $indentation-step);
  //
  slot output-info-guts-stream :: <stream>,
    init-function: curry(make-indenting-string-stream,
			 indentation: $indentation-step);
  //
  slot output-info-local-vars :: <object-table>,
    init-function: curry(make, <object-table>);
  //
  // id number for the next block.
  slot output-info-next-block :: <fixed-integer>, init-value: 0;
  //
  // id number for the next local.  Reset at the start of each function.
  slot output-info-next-local :: <fixed-integer>, init-value: 0;
  //
  // id number for the next global.
  slot output-info-next-global :: <fixed-integer>, init-value: 0;
  //
  // Vector of the initial values for the roots vector.
  slot output-info-init-roots :: <stretchy-vector>,
    init-function: curry(make, <stretchy-vector>);
  //
  // Hash table mapping constants to indices in the roots table.
  slot output-info-constants :: <table>,
    init-function: curry(make, <object-table>);
  //
  // C variable holding the current stack top.
  slot output-info-cur-stack-depth :: <fixed-integer>,
    init-value: 0;
end;



// Utilities.

define method get-info-for (thing :: <annotatable>,
			    output-info :: <output-info>)
    => res :: <object>;
  thing.info | (thing.info := make-info-for(thing, output-info));
end;

define method new-local (output-info :: <output-info>)
    => res :: <string>;
  let num = output-info.output-info-next-local;
  output-info.output-info-next-local := num + 1;

  format-to-string("L%d", num);
end;

define method new-global (output-info :: <output-info>)
    => res :: <string>;
  let num = output-info.output-info-next-global;
  output-info.output-info-next-global := num + 1;

  format-to-string("G%d", num);
end;

define method new-root (init-value :: union(<false>, <ct-value>),
			output-info :: <output-info>)
  let roots = output-info.output-info-init-roots;
  let index = roots.size;
  add!(roots, init-value);

  format-to-string("roots[%d]", index);
end;

define method cluster-names (depth :: <fixed-integer>)
    => (bottom-name :: <string>, top-name :: <string>);
  if (zero?(depth))
    values("orig_sp", "cluster_0_top");
  else
    values(format-to-string("cluster_%d_top", depth - 1),
	   format-to-string("cluster_%d_top", depth));
  end;
end;

define method consume-cluster
    (cluster :: <abstract-variable>, output-info :: <output-info>)
    => (bottom-name :: <string>, top-name :: <string>);
  let depth = cluster.info;
  if (depth >= output-info.output-info-cur-stack-depth)
    error("Consuming a cluster that isn't on the stack?");
  end;
  output-info.output-info-cur-stack-depth := depth;
  cluster-names(depth);
end;

define method produce-cluster
    (cluster :: <abstract-variable>, output-info :: <output-info>)
    => (bottom-name :: <string>, top-name :: <string>);
  let depth = cluster.info;
  if (depth > output-info.output-info-cur-stack-depth)
    error("Leaving a gap when producing a cluster?");
  end;
  output-info.output-info-cur-stack-depth := depth + 1;
  cluster-names(depth);
end;

define method produce-cluster
    (cluster :: <initial-definition>, output-info :: <output-info>)
    => (bottom-name :: <string>, top-name :: <string>);
  produce-cluster(cluster.definition-of, output-info);
end;




// variable stuff.

define class <backend-var-info> (<object>)
  slot backend-var-info-rep :: <representation>,
    required-init-keyword: representation:;
  slot backend-var-info-name :: union(<false>, <string>),
    required-init-keyword: name:;
end;

define method make-info-for (var :: union(<initial-variable>, <ssa-variable>),
			     // ### Should really only be ssa-variable.
			     output-info :: <output-info>)
    => res :: <backend-var-info>;
  let varinfo = var.var-info;
  let rep = pick-representation(var.derived-type, #"speed");
  make(<backend-var-info>, representation: rep, name: #f);
end;

define method make-info-for (defn :: <definition>,
			     output-info :: <output-info>)
    => res :: <backend-var-info>;
  let type = defn.defn-type;
  let rep = if (type)
	      pick-representation(type, #"speed");
	    else
	      $general-rep;
	    end;
  if (instance?(rep, <immediate-representation>))
    let name = new-global(output-info);
    make(<backend-var-info>, representation: rep, name: name);
  else
    let name = new-root(defn.ct-value, output-info);
    make(<backend-var-info>, representation: $general-rep, name: name);
  end;
end;


define method get-info-for (leaf :: <initial-definition>,
			    output-info :: <output-info>)
    => res :: <backend-var-info>;
  get-info-for(leaf.definition-of, output-info);
end;

define method get-info-for (leaf :: <global-variable>,
			    output-info :: <output-info>)
    => res :: <backend-var-info>;
  get-info-for(leaf.var-info.var-defn, output-info);
end;

define method c-name-and-rep (leaf :: <abstract-variable>,
			      // ### Should really be ssa-variable
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  let info = get-info-for(leaf, output-info);
  let name = info.backend-var-info-name;
  unless (name)
    name := new-local(output-info);
    let stream = output-info.output-info-vars-stream;
    format(stream, "%s %s;",
	   info.backend-var-info-rep.representation-c-type, name);
    if (instance?(leaf.var-info, <debug-named-info>))
      format(stream, " /* %s */", leaf.var-info.debug-name);
    end;
    write('\n', stream);
    info.backend-var-info-name := name;
  end;
  values(name, info.backend-var-info-rep);
end;

define method variable-representation (leaf :: <abstract-variable>,
				       // ### Should really be ssa-variable
				       output-info :: <output-info>)
    => rep :: <representation>;
  get-info-for(leaf, output-info).backend-var-info-rep;
end;



// function region stuff.

define class <function-info> (<object>)
  slot function-info-name :: <byte-string>,
    required-init-keyword: name:;
  slot function-info-prototype :: <byte-string>,
    required-init-keyword: prototype:;
  slot function-info-argument-representations :: <list>,
    required-init-keyword: argument-reps:;
  slot function-info-result-representation
    :: type-or(<representation>, <list>,
	       one-of(#"doesn't-return", #"cluster", #"void")),
    required-init-keyword: result-rep:;
end;

define method make-info-for
    (function :: <fer-function-region>, output-info :: <output-info>)
    => res :: <function-info>;
  // Compute the prototype.

  let stream = make(<byte-string-output-stream>);
  let name = new-global(output-info);
  let result-type = function.result-type;
  let result-rep
    = if (function.return-convention == #"cluster")
	write("descriptor_t *", stream);
	#"cluster";
      elseif (result-type == empty-ctype())
	write("void", stream);
	#"doesn't-return";
      else
	let min-values = result-type.min-values;
	let positionals = result-type.positional-types;
	let rest-type = result-type.rest-value-type;
	if (min-values == positionals.size & rest-type == empty-ctype())
	  if (min-values == 0)
	    write("void", stream);
	    #"void";
	  elseif (min-values == 1)
	    let rep = pick-representation(result-type, #"speed");
	    write(rep.representation-c-type, stream);
	    rep;
	  else
	    let header = output-info.output-info-header-stream;
	    format(header, "struct %s_results {\n", name);
	    let reps
	      = map(method (type, index)
		      let rep = pick-representation(type, #"speed");
		      format(header, "    %s R%d;\n",
			     rep.representation-c-type, index);
		      rep;
		    end,
		    positionals,
		    make(<range>, from: 0));
	    format(header, "};\n\n");
	    format(stream, "struct %s_results", name);
	    reps;
	  end;
	else
	  write("descriptor_t *", stream);
	  #"cluster";
	end;
      end;

  format(stream, " %s(descriptor_t *orig_sp", name);
  let argument-reps = #();
  for (arg-type in function.argument-types,
       index from 0,
       var = function.prologue.dependents.dependent.defines
	 then var & var.definer-next)
    let rep = pick-representation(arg-type, #"speed");
    format(stream, ", %s A%d", rep.representation-c-type, index);
    if (var)
      let varinfo = var.var-info;
      if (instance?(varinfo, <debug-named-info>))
	format(stream, " /* %s */", varinfo.debug-name);
      end;
    end;
    argument-reps := pair(rep, argument-reps);
  end;
  write(')', stream);

  make(<function-info>,
       name: name,
       prototype: stream.string-output-stream-string,
       argument-reps: reverse!(argument-reps),
       result-rep: result-rep);
end;


// Prologue and epilogue stuff.

define method emit-prologue (output-info :: <output-info>) => ();
  let bstream = output-info.output-info-body-stream;
  format(bstream, "#include <stdlib.h>\n\n");

  let header = output-info.output-info-header-stream;
  format(header, "typedef struct heapptr *heapptr_t;\n");
  format(header, "typedef struct {\n");
  format(header, "    heapptr_t heapptr;\n");
  format(header, "    union {\n");
  format(header, "        long l;\n");
  format(header, "        float f;\n");
  if (instance?(*double-rep*, <data-word-representation>))
    format(header, "        double d;\n");
  end;
  if (instance?(*long-double-rep*, <data-word-representation>))
    format(header, "        long double x;\n");
  end;
  format(header, "        void *ptr;\n");
  format(header, "    } dataword;\n");
  format(header, "} descriptor_t;\n\n");
  format(header, "typedef int boolean;\n");
  format(header, "#define TRUE 1;\n");
  format(header, "#define FALSE 0;\n\n");
  format(header, "#define SLOTADDR(ptr, type, offset) "
	   "((type *)((char *)ptr + offset))\n");
  format(header, "#define SLOT(ptr, type, offset) "
	   "(*SLOTADDR(ptr, type, offset))\n\n");
  format(header, "typedef descriptor_t *(*entry_t)();\n");
  format(header, "#define GENERAL_ENTRY(func) \\\n");
  format(header, "    ((entry_t)SLOT(func, void *, /* ### */ 0))\n");
  format(header, "#define GENERIC_ENTRY(func) \\\n");
  format(header, "    ((entry_t)SLOT(func, void *, /* ### */ 0))\n\n");
  format(header, "extern heapptr_t allocate(int bytes);\n");
  format(header,
	 "extern descriptor_t *values_sequence"
	   "(descriptor_t *sp, heapptr_t vector);\n");
  format(header,
	 "extern heapptr_t make_rest_arg(descriptor_t *start, long count);\n");
  unless (instance?(*double-rep*, <data-word-representation>))
    format(header, "extern heapptr_t make_double_float(double value);\n");
    format(header, "extern double double_float_value(heapptr_t df);\n");
  end;
  unless (instance?(*long-double-rep*, <data-word-representation>))
    format(header,
	   "extern heapptr_t make_extended_float(long double value);\n");
    format(header, "extern long double extended_float_value(heapptr_t xf);\n");
  end;
  format(header, "\nextern descriptor_t roots[];\n\n");
  format(header, "#define obj_True %s.heapptr\n",
	 new-root(as(<ct-value>, #t), output-info));
  format(header, "#define obj_False %s.heapptr\n\n",
	 new-root(as(<ct-value>, #f), output-info));
end;

define method emit-epilogue
    (init-function :: <function-region>, output-info :: <output-info>) => ();
  let bstream = output-info.output-info-body-stream;
  let gstream = output-info.output-info-guts-stream;

  format(bstream, "heapptr_t allocate(int bytes)\n{\n");
  format(gstream, "return malloc(bytes);\n");
  write(gstream.string-output-stream-string, bstream);
  write("}\n\n", bstream);
  
  format(bstream,
	 "descriptor_t *values_sequence"
	   "(descriptor_t *sp, heapptr_t vector)\n{\n");
  format(gstream, "long elements = SLOT(vector, long, /* ### */ 0);\n");
  format(gstream, "memcpy(sp, SLOTADDR(vector, descriptor_t, /* ### */ 0),\n");
  format(gstream, "       elements * sizeof(descriptor_t));\n");
  format(gstream, "return sp + elements;\n");
  write(gstream.string-output-stream-string, bstream);
  write("}\n\n", bstream);

  format(bstream,
	 "heapptr_t make_rest_arg(descriptor_t *start, long count)\n{\n");
  format(gstream, "return NULL; /* ### */\n");
  write(gstream.string-output-stream-string, bstream);
  write("}\n\n", bstream);

  unless (instance?(*double-rep*, <data-word-representation>))
    let cclass = specifier-type(#"<double-float>");
    format(bstream, "heapptr_t make_double_float(double value)\n{\n");
    format(gstream, "heapptr_t res = allocate(%d);\n",
	   cclass.instance-slots-layout.layout-length);
    let (expr, rep) = c-expr-and-rep(cclass, $heap-rep, output-info);
    format(gstream, "SLOT(res, heapptr_t, %d) = %s;\n",
	   dylan-slot-offset(cclass, #"%object-class"),
	   conversion-expr($heap-rep, expr, rep, output-info));
    let value-offset = dylan-slot-offset(cclass, #"value");
    format(gstream, "SLOT(res, double, %d) = value;\n", value-offset);
    format(gstream, "return res;\n");
    write(gstream.string-output-stream-string, bstream);
    write("}\n\n", bstream);

    format(bstream, "double double_float_value(heapptr_t df)\n{\n");
    format(gstream, "return SLOT(df, double, %d);\n", value-offset);
    write(gstream.string-output-stream-string, bstream);
    write("}\n\n", bstream);
  end;

  unless (instance?(*long-double-rep*, <data-word-representation>))
    let cclass = specifier-type(#"<extended-float>");
    format(bstream, "heapptr_t make_extended_float(long double value)\n{\n");
    format(gstream, "heapptr_t res = allocate(%d);\n",
	   cclass.instance-slots-layout.layout-length);
    let (expr, rep) = c-expr-and-rep(cclass, $heap-rep, output-info);
    format(gstream, "SLOT(res, heapptr_t, %d) = %s;\n",
	   dylan-slot-offset(cclass, #"%object-class"),
	   conversion-expr($heap-rep, expr, rep, output-info));
    let value-offset = dylan-slot-offset(cclass, #"value");
    format(gstream, "SLOT(res, long double, %d) = value;\n", value-offset);
    format(gstream, "return res;\n");
    write(gstream.string-output-stream-string, bstream);
    write("}\n\n", bstream);

    format(bstream, "long double extended_float_value(heapptr_t xf)\n{\n");
    format(gstream, "return SLOT(xf, long double, %d);\n", value-offset);
    write(gstream.string-output-stream-string, bstream);
    write("}\n\n", bstream);
  end;

  format(bstream, "void main(int argc, char *argv[])\n{\n");
  format(gstream, "descriptor_t *sp = malloc(64*1024);\n\n");
  let func-info = get-info-for(init-function, output-info);
  format(gstream, "%s(sp);\n", func-info.function-info-name);
  write(gstream.string-output-stream-string, bstream);
  write("}\n", bstream);
end;

define method dylan-slot-offset (cclass :: <cclass>, slot-name :: <symbol>)
  block (return)
    for (slot in cclass.all-slot-infos)
      if (slot.slot-getter & slot.slot-getter.variable-name == slot-name)
	return(find-slot-offset(slot, cclass)
		 | error("%s isn't at a constant offset in %=",
			 slot-name, cclass));
      end;
    end;
    error("%= doesn't have a slot named %s", cclass, slot-name);
  end;
end;


// Top level form processors.

define generic emit-tlf-gunk (tlf :: <top-level-form>,
			      output-info :: <output-info>)
    => ();

define method emit-tlf-gunk (tlf :: <top-level-form>,
			     output-info :: <output-info>)
    => ();
end;

define method emit-tlf-gunk (tlf :: <define-bindings-tlf>,
			     output-info :: <output-info>)
    => ();
  for (defn in tlf.tlf-required-defns)
    emit-bindings-definition-gunk(defn, output-info);
  end;
  if (tlf.tlf-rest-defn)
    emit-bindings-definition-gunk(tlf.tlf-rest-defn, output-info);
  end;
end;

define method emit-bindings-definition-gunk
    (defn :: <bindings-definition>, output-info :: <output-info>) => ();
  let info = get-info-for(defn, output-info);
  let stream = output-info.output-info-header-stream;
  let rep = info.backend-var-info-rep;
  if (instance?(rep, <immediate-representation>))
    format(stream, "static %s %s",
	   rep.representation-c-type,
	   info.backend-var-info-name);
    let init-value = defn.ct-value;
    if (init-value)
      let (init-value-expr, init-value-rep)
	= c-expr-and-rep(init-value, rep, output-info);
      format(stream, "= %s;\t/* %s */\n\n",
	     conversion-expr(rep, init-value-expr, init-value-rep,
			     output-info),
	     defn.defn-name);
    else
      format(stream, ";\t/* %s */\nstatic int %s_initialized = FALSE;\n\n",
	     defn.defn-name,
	     info.backend-var-info-name);
    end;
  else
    format(stream, "/* %s allocated as %s */\n\n",
	   defn.defn-name,
	   info.backend-var-info-name);
  end;
end;

define method emit-bindings-definition-gunk
    (defn :: <variable-definition>, output-info :: <output-info>,
     #next next-method)
    => ();
  next-method();
  let type-defn = defn.var-defn-type-defn;
  if (type-defn)
    emit-bindings-definition-gunk(type-defn, output-info);
  end;
end;

define method emit-bindings-definition-gunk
    (defn :: <constant-definition>, output-info :: <output-info>,
     #next next-method)
    => ();
  unless (instance?(defn.ct-value, <eql-ct-value>))
    next-method();
  end;
end;

define method emit-bindings-definition-gunk
    (defn :: <constant-method-definition>, output-info :: <output-info>,
     #next next-method)
    => ();
  unless (defn.method-defn-leaf)
    next-method();
  end;
end;


// Control flow emitters

define method emit-function
    (function :: <fer-function-region>, output-info :: <output-info>)
    => ();
  output-info.output-info-next-block := 0;
  output-info.output-info-next-local := 0;
  output-info.output-info-cur-stack-depth := 0;
  assert(output-info.output-info-local-vars.size == 0);

  let function-info = get-info-for(function, output-info);
  let prototype = function-info.function-info-prototype;
  format(output-info.output-info-header-stream,
	 "/* %s */\n%s;\n\n",
	 function.name, prototype);

  let stream = output-info.output-info-body-stream;
  format(stream, "/* %s */\n", function.name);
  format(stream, "%s\n{\n", prototype);

  let max-depth = analize-stack-usage(function);
  for (i from 0 below max-depth)
    format(output-info.output-info-vars-stream,
	   "descriptor_t *cluster_%d_top;\n",
	   i);
  end;

  emit-region(function.body, output-info);

  write(output-info.output-info-vars-stream.string-output-stream-string,
	stream);
  write('\n', stream);
  write(output-info.output-info-guts-stream.string-output-stream-string,
	stream);
  write("}\n\n", stream);
end;

define method emit-region (region :: <simple-region>,
			   output-info :: <output-info>)
    => ();
  for (assign = region.first-assign then assign.next-op,
       while: assign)
    emit-assignment(assign.defines, assign.depends-on.source-exp, output-info);
  end;
end;

define method emit-region (region :: <compound-region>,
			   output-info :: <output-info>)
    => ();
  for (subregion in region.regions)
    emit-region(subregion, output-info);
  end;
end;

define method emit-region (region :: <if-region>, output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let cond = ref-leaf($boolean-rep, region.depends-on.source-exp, output-info);
  let initial-depth = output-info.output-info-cur-stack-depth;
  format(stream, "if (%s) {\n", cond);
  indent(stream, $indentation-step);
  emit-region(region.then-region, output-info);
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  indent(stream, -$indentation-step);
  write("}\n", stream);
  let after-then-depth = output-info.output-info-cur-stack-depth;
  output-info.output-info-cur-stack-depth := initial-depth;
  write("else {\n", stream);
  indent(stream, $indentation-step);
  emit-region(region.else-region, output-info);
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  indent(stream, -$indentation-step);
  write("}\n", stream);
  let after-else-depth = output-info.output-info-cur-stack-depth;
  output-info.output-info-cur-stack-depth
    := max(after-then-depth, after-else-depth);
end;

define method emit-region (region :: <loop-region>,
			   output-info :: <output-info>)
    => ();
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  let stream = output-info.output-info-guts-stream;
  write("while (1) {\n", stream);
  indent(stream, $indentation-step);
  emit-region(region.body, output-info);
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  indent(stream, -$indentation-step);
  write("}\n", stream);
end;

define method make-info-for
    (block-region :: <block-region>, output-info :: <output-info>) => res;
  let id = output-info.output-info-next-block;
  output-info.output-info-next-block := id + 1;
  id;
end;

define method emit-region (region :: <block-region>,
			   output-info :: <output-info>)
    => ();
  unless (region.exits)
    error("A block with no exits still exists?");
  end;
  let stream = output-info.output-info-guts-stream;
  emit-region(region.body, output-info);
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  let half-step = ash($indentation-step, -1);
  indent(stream, - half-step);
  format(stream, "block%d:;\n", get-info-for(region, output-info));
  indent(stream, half-step);
end;

define method emit-region (region :: <unwind-protect-region>,
			   output-info :: <output-info>)
    => ();
  emit-region(region.body, output-info);
end;

define method emit-region (region :: <exit>, output-info :: <output-info>)
    => ();
  /* ### emit-joins(region.join-region, output-info); */
  spew-pending-defines(output-info);
  let stream = output-info.output-info-guts-stream;
  let target = region.block-of;
  for (region = region.parent then region.parent,
       until: region == #f | region == target)
    finally
    unless (region)
      error("Non-local raw exit?");
    end;
  end;
  if (instance?(target, <block-region>))
    format(stream, "goto block%d;\n", get-info-for(target, output-info));
  else
    format(stream, "abort();\n");
  end;
end;

define method emit-region (return :: <return>, output-info :: <output-info>)
    => ();
  /* ### emit-joins(region.join-region, output-info); */
  let function :: <fer-function-region> = return.block-of;
  let function-info = get-info-for(function, output-info);
  let result-rep = function-info.function-info-result-representation;
  emit-return(return, result-rep, output-info);
end;

define method emit-return
    (return :: <return>, result-rep == #"doesn't-return",
     output-info :: <output-info>)
    => ();
  error("have a return region for a function that doesn't return?");
end;

define method emit-return
    (return :: <return>, result-rep == #"void", output-info :: <output-info>)
    => ();
  spew-pending-defines(output-info);
  write("return;\n", output-info.output-info-guts-stream);
end;

define method emit-return
    (return :: <return>, result-rep == #"cluster",
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let results = return.depends-on;
  if (results & instance?(results.source-exp, <abstract-variable>)
	& instance?(results.source-exp.var-info, <values-cluster-info>))
    let (bottom-name, top-name)
      = consume-cluster(results.source-exp, output-info);
    unless (bottom-name = "orig_sp")
      error("Delivering a cluster that isn't at the bottom of the frame?");
    end;
    spew-pending-defines(output-info);
    format(stream, "return %s;\n", top-name);
  else
    for (dep = results then dep.dependent-next,
	 count from 0,
	 while: dep)
      format(stream, "orig_sp[%d] = %s;\n", count,
	     ref-leaf($general-rep, dep.source-exp, output-info));
    finally
      spew-pending-defines(output-info);
      format(stream, "return orig_sp + %d;\n", count);
    end;
  end;
end;

define method emit-return
    (return :: <return>, result-rep :: <representation>,
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let expr = ref-leaf(result-rep, return.depends-on.source-exp, output-info);
  spew-pending-defines(output-info);
  format(stream, "return %s;\n", expr);
end;

define method emit-return
    (return :: <return>, result-reps :: <list>, output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;  
  let temp = new-local(output-info);
  let function = return.block-of;
  let function-info = get-info-for(function, output-info);
  let name = function-info.function-info-name;
  format(output-info.output-info-vars-stream, "struct %s_results %s;\n",
	 name, temp);
  for (rep in result-reps,
       index from 0,
       dep = return.depends-on then dep.dependent-next)
    format(stream, "%s.R%d = %s;\n",
	   temp, index, ref-leaf(rep, dep.source-exp, output-info));
  end;
  spew-pending-defines(output-info);
  format(stream, "return %s;\n", temp);
end;


define method block-id (region :: <false>) => id :: <false>;
  #f;
end;

define method block-id (region :: <region>) => id :: false-or(<fixed-integer>);
  region.parent.block-id;
end;

define method block-id (region :: <block-region>)
    => id :: false-or(<fixed-integer>);
  let parent-id = region.parent.block-id;
  if (~region.exits)
    parent-id;
  elseif (parent-id)
    parent-id + 1;
  else
    0;
  end;
end;



// Assignments.

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       var :: <abstract-variable>,
			       output-info :: <output-info>)
    => ();
  if (defines)
    if (instance?(var.var-info, <values-cluster-info>))
      let (bottom-name, top-name) = consume-cluster(var, output-info);
      deliver-cluster(defines, bottom-name, top-name, var.derived-type,
		      output-info);
    else
      let rep = if (instance?(defines.var-info, <values-cluster-info>))
		  $general-rep;
		else
		  variable-representation(defines, output-info)
		end;

      deliver-result(defines, ref-leaf(rep, var, output-info), rep, #f,
		     output-info);
    end;
  end;
end;

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       expr :: <global-variable>,
			       output-info :: <output-info>)
    => ();
  let (name, rep) = c-name-and-rep(expr, output-info);
  if (~expr.var-info.var-defn.ct-value)
    let stream = output-info.output-info-guts-stream;
    if (rep.representation-has-bottom-value?)
      let temp = new-local(output-info);
      format(output-info.output-info-vars-stream, "%s %s;\n",
	     rep.representation-c-type, temp);
      format(stream, "if ((%s = %s) == NULL) abort();\n", temp, name);
      name := temp;
    else
      format(stream, "if (!%s_initialized) abort();\n", name);
    end;
  end;
  deliver-result(defines, name, rep, #f, output-info);
end;

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       expr :: <literal-constant>,
			       output-info :: <output-info>)
    => ();
  if (defines)
    let rep-hint = if (instance?(defines.var-info, <values-cluster-info>))
		     $general-rep;
		   else
		     variable-representation(defines, output-info)
		   end;
    let (expr, rep) = c-expr-and-rep(expr.value, rep-hint, output-info);
    deliver-result(defines, expr, rep, #f, output-info);
  end;
end;

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       leaf :: <definition-constant-leaf>,
			       output-info :: <output-info>)
    => ();
  let info = get-info-for(leaf.const-defn, output-info);
  deliver-result(defines, info.backend-var-info-name,
		  info.backend-var-info-rep, #f, output-info);
end;

define method emit-assignment (results :: false-or(<definition-site-variable>),
			       leaf :: <uninitialized-value>,
			       output-info :: <output-info>)
    => ();
  if (results)
    let rep = variable-representation(results, output-info);
    if (rep == $general-rep)
      deliver-result(results, "0", $heap-rep, #f, output-info);
    else
      deliver-result(results, "0", rep, #f, output-info);
    end;
  end;
end;

define method emit-assignment
    (results :: false-or(<definition-site-variable>),
     call :: union(<unknown-call>, <error-call>),
     output-info :: <output-info>)
    => ();
  let setup-stream = make(<byte-string-output-stream>);
  let function = call.depends-on.source-exp;
  let use-generic-entry?
    = instance?(call, <unknown-call>) & call.use-generic-entry?;
  let (next-info, arguments)
    = if (use-generic-entry?)
	let dep = call.depends-on.dependent-next;
	values(ref-leaf($heap-rep, dep.source-exp, output-info),
	       dep.dependent-next);
      else
	values(#f, call.depends-on.dependent-next);
      end;
  let (args, sp) = cluster-names(output-info.output-info-cur-stack-depth);
  for (arg-dep = arguments then arg-dep.dependent-next,
       count from 0,
       while: arg-dep)
    format(setup-stream, "%s[%d] = %s;\n", args, count,
	   ref-leaf($general-rep, arg-dep.source-exp, output-info));
  finally
    let (entry, name)
      = xep-expr-and-name(function, use-generic-entry?, output-info);
    let func = ref-leaf($heap-rep, function, output-info);
    spew-pending-defines(output-info);
    let stream = output-info.output-info-guts-stream;
    write(setup-stream.string-output-stream-string, stream);
    if (name)
      format(stream, "/* %s */\n", name);
    end;
    if (results)
      format(stream, "%s = ", sp);
    end;
    format(stream, "%s(%s + %d, %s, %d", entry, args, count, func, count);
    if (next-info)
      write(", ", stream);
      write(next-info, stream);
    end;
    write(");\n", stream);
    deliver-cluster(results, args, sp, call.derived-type, output-info);
  end;
end;

define method xep-expr-and-name
    (func :: <leaf>, generic-entry? :: <boolean>, output-info :: <output-info>)
    => (expr :: <string>, name :: false-or(<string>));
  spew-pending-defines(output-info);
  values(format-to-string(if (generic-entry?)
			    "GENERIC_ENTRY(%s)";
			  else
			    "GENERAL_ENTRY(%s)";
			  end,
			  ref-leaf($heap-rep, func, output-info)),
	 #f);
end;

define method xep-expr-and-name
    (func :: <function-literal>, generic-entry? :: <boolean>,
     output-info :: <output-info>)
    => (expr :: <string>, name :: <string>);
  if (generic-entry?)
    error("%= doesn't have a generic entry.", func);
  end;
  let general-entry = func.general-entry;
  let entry-info = get-info-for(general-entry, output-info);
  values(entry-info.function-info-name, general-entry.name);
end;

define method xep-expr-and-name
    (func :: <method-literal>, generic-entry? :: <true>,
     output-info :: <output-info>)
    => (expr :: <string>, name :: <string>);
  let generic-entry = func.generic-entry;
  let entry-info = get-info-for(generic-entry, output-info);
  values(entry-info.function-info-name, generic-entry.name);
end;

define method xep-expr-and-name
    (func :: <definition-constant-leaf>, generic-entry? :: <boolean>,
     output-info :: <output-info>,
     #next next-method)
    => (expr :: <string>, name :: <string>);
  let defn = func.const-defn;
  let (expr, name) = xep-expr-and-name(defn, generic-entry?, output-info);
  values(expr | next-method(),
	 name | format-to-string("%s", defn.defn-name));
end;

define method xep-expr-and-name
    (defn :: <abstract-constant-definition>, generic-entry? :: <boolean>,
     output-info :: <output-info>)
    => (expr :: false-or(<string>), name :: false-or(<string>));
  values(#f, #f);
end;

define method xep-expr-and-name
    (defn :: <abstract-method-definition>, generic-entry? :: <boolean>,
     output-info :: <output-info>)
    => (expr :: false-or(<string>), name :: false-or(<string>));
  let leaf = defn.method-defn-leaf;
  if (leaf)
    xep-expr-and-name(leaf, generic-entry?, output-info);
  else
    values(#f, #f);
  end;
end;


define method emit-assignment
    (results :: false-or(<definition-site-variable>), call :: <known-call>,
     output-info :: <output-info>)
    => ();

  let function = call.depends-on.source-exp;
  let main-entry = find-main-entry(function);

  let func-info = get-info-for(main-entry, output-info);
  let stream = make(<byte-string-output-stream>);
  let c-name = func-info.function-info-name;
  let (sp, new-sp) = cluster-names(output-info.output-info-cur-stack-depth);
  format(stream, "%s(%s", c-name, sp);
  for (arg-dep = call.depends-on.dependent-next then arg-dep.dependent-next,
       rep in func-info.function-info-argument-representations)
    unless (arg-dep)
      error("Not enough arguments in a known call?");
    end;
      write(", ", stream);
      write(ref-leaf(rep, arg-dep.source-exp, output-info), stream);
  finally
    if (arg-dep)
      error("Too many arguments in a known call?");
    end;
  end;
  write(')', stream);
  let call = string-output-stream-string(stream);
  format(output-info.output-info-guts-stream, "/* %s */\n", main-entry.name);
  let result-rep = func-info.function-info-result-representation;
  if (results == #f | result-rep == #"void")
    format(output-info.output-info-guts-stream, "%s;\n", call);
    deliver-results(results, #[], #f, output-info);
  elseif (result-rep == #"doesn't-return")
    error("Trying to get some values back from a function that "
	    "doesn't return?");
  elseif (result-rep == #"cluster")
    format(output-info.output-info-guts-stream, "%s = %s;\n", new-sp, call);
    deliver-cluster(results, sp, new-sp, main-entry.result-type, output-info);
  elseif (instance?(result-rep, <list>))
    let temp = new-local(output-info);
    format(output-info.output-info-vars-stream, "struct %s_results %s;\n",
	   c-name, temp);
    format(output-info.output-info-guts-stream, "%s = %s;\n", temp, call);
    let result-exprs = make(<vector>, size: result-rep.size);
    for (rep in result-rep,
	 index from 0)
      result-exprs[index]
	:= pair(format-to-string("%s.R%d", temp, index), rep);
    end;
    deliver-results(results, result-exprs, #f, output-info);
  else
    deliver-result(results, call, result-rep, #t, output-info);
  end;
end;

define method find-main-entry
    (func :: <function-literal>) => res :: <fer-function-region>;
  func.main-entry;
end;

define method find-main-entry
    (func :: <definition-constant-leaf>) => res :: <fer-function-region>;
  find-main-entry(func.const-defn);
end;

define method find-main-entry
    (defn :: <generic-definition>) => res :: <fer-function-region>;
  let discriminator = defn.generic-defn-discriminator-leaf;
  if (discriminator)
    find-main-entry(discriminator);
  else
    error("Known call of a generic function without a static discriminator?");
  end;
end;

define method find-main-entry
    (defn :: <abstract-method-definition>) => res :: <fer-function-region>;
  find-main-entry(defn.method-defn-leaf);
end;



define method emit-assignment
    (results :: false-or(<definition-site-variable>), call :: <mv-call>, 
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let function = call.depends-on.source-exp;
  let use-generic-entry? = call.use-generic-entry?;
  let (next-info, cluster)
    = if (use-generic-entry?)
	let dep = call.depends-on.dependent-next;
	values(ref-leaf($heap-rep, dep.source-exp, output-info),
	       dep.dependent-next.source-exp);
      else
	values(#f, call.depends-on.dependent-next.source-exp);
      end;
  let (entry, name)
    = xep-expr-and-name(function, use-generic-entry?, output-info);
  let func = ref-leaf($heap-rep, function, output-info);
  spew-pending-defines(output-info);
  let (bottom-name, top-name) = consume-cluster(cluster, output-info);
  if (name)
    format(stream, "/* %s */\n", name);
  end;
  if (results)
    format(stream, "%s = ", top-name);
  end;
  format(stream, "%s(%s, %s, %s - %s",
	 entry, top-name, func, top-name, bottom-name);
  if (next-info)
    write(", ", stream);
    write(next-info, stream);
  end;
  write(");\n", stream);
  deliver-cluster(results, bottom-name, top-name, call.derived-type,
		  output-info);
end;

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       expr :: <primitive>,
			       output-info :: <output-info>)
    => ();
  let emitter = expr.info.primitive-emitter;
  unless (emitter)
    error("Unknown primitive: %s", expr.name);
  end;
  emitter(defines, expr, output-info);
end;

define method emit-assignment (defines :: false-or(<definition-site-variable>),
			       expr :: <prologue>,
			       output-info :: <output-info>)
    => ();
  let function-info = get-info-for(expr.function, output-info);
  deliver-results(defines,
		  map(method (rep, index)
			pair(format-to-string("A%d", index),
			     rep);
		      end,
		      function-info.function-info-argument-representations,
		      make(<range>, from: 0)),
		  #f, output-info);
end;

define method emit-assignment
    (defines :: false-or(<definition-site-variable>),
     set :: <set>, output-info :: <output-info>)
    => ();
  let defn = set.variable;
  let info = get-info-for(defn, output-info);
  let target = info.backend-var-info-name;
  let rep = info.backend-var-info-rep;
  let source = extract-operands(set, output-info, rep);
  spew-pending-defines(output-info);
  emit-copy(target, rep, source, rep, output-info);
  unless (defn.ct-value)
    unless (rep.representation-has-bottom-value?)
      let stream = output-info.output-info-guts-stream;
      format(stream, "%s_initialized = TRUE;\n", target);
    end;
  end;
  deliver-results(defines, #[], #f, output-info);
end;

define method emit-assignment
    (results :: false-or(<definition-site-variable>),
     call :: <self-tail-call>, output-info :: <output-info>)
    => ();
  spew-pending-defines(output-info);
  let function = call.self-tail-call-of;
  for (param = function.prologue.dependents.dependent.defines
	 then param.definer-next,
       closure-var = function.environment.closure-vars
	 then closure-var.closure-next,
       while: closure-var & param)
  finally
    let stream = output-info.output-info-guts-stream;
    for (param = param then param.definer-next,
	 arg-dep = call.depends-on then arg-dep.dependent-next,
	 while: arg-dep & param)
      let (name, rep) = c-name-and-rep(param, output-info);
      format(stream, "%s = %s;\n",
	     name, ref-leaf(rep, arg-dep.source-exp, output-info));
    finally
      if (arg-dep | param)
	error("Wrong number of operands in a self-tail-call?");
      end;
    end;
  end;
  deliver-results(results, #[], #f, output-info);
end;

define method emit-assignment
    (results :: false-or(<definition-site-variable>),
     op :: <slot-ref>, output-info :: <output-info>)
    => ();
  let offset = op.slot-offset;
  let instance-leaf = op.depends-on.source-exp;
  let instance-rep = pick-representation(instance-leaf.derived-type, #"speed");
  let slot = op.slot-info;
  let slot-rep = slot.slot-representation;
  let (expr, now-dammit?)
    = if (~zero?(offset) & instance?(instance-rep, <immediate-representation>))
	// Extracting the data-word.
	unless (instance-rep == slot-rep
		  | (representation-data-word-member(instance-rep)
		       = representation-data-word-member(slot-rep)))
	  error("The instance and slot representations don't match in a "
		  "data-word reference?");
	end;
	values(ref-leaf(instance-rep, instance-leaf, output-info), #f);
      else
	let instance-expr = ref-leaf($heap-rep, instance-leaf, output-info);
	let offset-expr
	  = if (op.depends-on.dependent-next)
	      let index = ref-leaf(*long-rep*,
				   op.depends-on.dependent-next.source-exp,
				   output-info);
	      format-to-string("%d + %s * sizeof(%s)",
			       offset, index, slot-rep.representation-c-type);
	    else
	      format-to-string("%d", offset);
	    end;
	spew-pending-defines(output-info);
	values(format-to-string("SLOT(%s, %s, %s)",
				instance-expr,
				slot-rep.representation-c-type,
				offset-expr),
	       ~slot.slot-read-only?);
      end;
  deliver-result(results, expr, slot-rep, now-dammit?, output-info);
end;

define method emit-assignment
    (results :: false-or(<definition-site-variable>),
     op :: <slot-set>, output-info :: <output-info>)
    => ();
  let slot = op.slot-info;
  let offset = op.slot-offset;
  let slot-rep = slot.slot-representation;
  if (instance?(slot, <vector-slot-info>))
    let (new, instance, index)
      = extract-operands(op, output-info, slot-rep, $heap-rep, *long-rep*);
    let c-type = slot-rep.representation-c-type;
    format(output-info.output-info-guts-stream,
	   "SLOT(%s, %s, %d + %s * sizeof(%s)) = %s;\n",
	   instance, c-type, offset, index, c-type, new);
  else
    let (new, instance)
      = extract-operands(op, output-info, slot-rep, $heap-rep);
    format(output-info.output-info-guts-stream,
	   "SLOT(%s, %s, %d) = %s;\n",
	   instance, slot-rep.representation-c-type, offset, new);
  end;
  deliver-results(results, #[], #f, output-info);
end;


define method emit-assignment
    (results :: false-or(<definition-site-variable>),
     op :: <truly-the>, output-info :: <output-info>)
    => ();
  if (results)
    let rep = variable-representation(results, output-info);
    let source = extract-operands(op, output-info, rep);
    deliver-result(results, source, rep, #f, output-info);
  end;
end;


define method deliver-cluster
    (defines :: false-or(<definition-site-variable>),
     src-start :: <string>, src-end :: <string>,
     type :: <values-ctype>, output-info :: <output-info>)
    => ();
  if (defines)
    let stream = output-info.output-info-guts-stream;
    if (instance?(defines.var-info, <values-cluster-info>))
      let (dst-start, dst-end) = produce-cluster(defines, output-info);
      if (src-start ~= dst-start)
	format(stream, "%s = %s;\n", dst-end, dst-start);
	format(stream, "while (%s < %s) {\n", src-start, src-end);
	format(stream, "    *%s++ = *%s++;\n", dst-end, src-start);
      elseif (src-end ~= dst-end)
	format(stream, "%s = %s;\n", dst-end, src-end);
      end;
    else
      let count = for (var = defines then var.definer-next,
		       index from 0,
		       while: var)
		  finally
		    index;
		  end;
      unless (count <= type.min-values)
	format(stream, "%s = pad_cluster(%s, %s, %d);\n",
	       src-end, src-start, src-end, count);
      end;
      for (var = defines then var.definer-next,
	   index from 0,
	   while: var)
	let source = format-to-string("%s[%d]", src-start, index);
	deliver-single-result(var, source, $general-rep, #t, output-info);
      end;
    end;
  end;
end;

define method deliver-results
    (defines :: false-or(<definition-site-variable>), values :: <sequence>,
     now-dammit? :: <boolean>, output-info :: <output-info>)
    => ();
  if (defines & instance?(defines.var-info, <values-cluster-info>))
    let stream = output-info.output-info-guts-stream;
    let (bottom-name, top-name) = produce-cluster(defines, output-info);
    format(stream, "%s = %s + %d;\n", top-name, bottom-name, values.size);
    for (val in values, index from 0)
      emit-copy(format-to-string("%s[%d]", bottom-name, index), $general-rep,
		val.head, val.tail, output-info);
    end;
  else
    for (var = defines then var.definer-next,
	 val in values,
	 while: var)
      deliver-single-result(var, val.head, val.tail, now-dammit?, output-info);
    finally
      if (var)
	let false = make(<literal-false>);
	for (var = var then var.definer-next,
	     while: var)
	  let target-rep = variable-representation(var, output-info);
	  let (source-name, source-rep)
	    = c-expr-and-rep(false, target-rep, output-info);
	  deliver-single-result(var, source-name, source-rep, #f, output-info);
	end;
      end;
    end;
  end;
end;

define method deliver-result
    (defines :: false-or(<definition-site-variable>), value :: <string>,
     rep :: <representation>, now-dammit? :: <boolean>,
     output-info :: <output-info>)
    => ();
  if (defines)
    if (instance?(defines.var-info, <values-cluster-info>))
      let stream = output-info.output-info-guts-stream;
      let (bottom-name, top-name) = produce-cluster(defines, output-info);
      format(stream, "%s = %s + 1;\n", top-name, bottom-name);
      emit-copy(format-to-string("%s[0]", bottom-name), $general-rep,
		value, rep, output-info);
    else
      deliver-single-result(defines, value, rep, now-dammit?, output-info);
      let next = defines.definer-next;
      if (next)
	let false = make(<literal-false>);
	for (var = next then var.definer-next,
	     while: var)
	  let target-rep = variable-representation(var, output-info);
	  let (source-name, source-rep)
	    = c-expr-and-rep(false, target-rep, output-info);
	  deliver-single-result(var, source-name, source-rep, #f, output-info);
	end;
      end;
    end;
  end;
end;

define method deliver-single-result
    (var :: <abstract-variable>, // ### Should really be ssa-variable
     source :: <string>, source-rep :: <representation>,
     now-dammit? :: <boolean>, output-info :: <output-info>)
    => ();
  if (var.dependents)
    if (now-dammit? | var.dependents.source-next)
      let (target-name, target-rep) = c-name-and-rep(var, output-info);
      emit-copy(target-name, target-rep, source, source-rep, output-info);
    else
      output-info.output-info-local-vars[var] := pair(source, source-rep);
    end;
  end;
end;

define method deliver-single-result
    (var :: <initial-definition>, source :: <string>,
     source-rep :: <representation>, now-dammit? :: <boolean>,
     output-info :: <output-info>)
    => ();
  spew-pending-defines(output-info);
  deliver-single-result(var.definition-of, source, source-rep, now-dammit?,
			output-info);
end;


// Primitives.

define-primitive-emitter
  (#"extract-args",
   method (results :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let nargs = extract-operands(operation, output-info, *long-rep*);
     let expr = format-to-string("((void *)(orig_sp - %s))", nargs);
     deliver-result(results, expr, *ptr-rep*, #f, output-info);
   end);

define-primitive-emitter
  (#"extract-arg",
   method (results :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (args, index) = extract-operands(operation, output-info,
					  *ptr-rep*, *long-rep*);
     let expr = format-to-string("(((descriptor_t *)%s)[%s])", args, index);
     deliver-result(results, expr, $general-rep, #t, output-info);
   end);

define-primitive-emitter
  (#"make-rest-arg",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (args, nfixed, nargs)
       = extract-operands(operation, output-info,
			  *ptr-rep*, *long-rep*, *long-rep*);
     let expr
       = format-to-string("make_rest_arg((descriptor_t *)%s + %s, %s - %s)",
			  args, nfixed, nargs, nfixed);
     deliver-result(defines, expr, $heap-rep, #t, output-info);
   end);

define-primitive-emitter
  (#"pop-args",
   method (results :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let args = extract-operands(operation, output-info, *ptr-rep*);
     spew-pending-defines(output-info);
     format(output-info.output-info-guts-stream, "orig_sp = %s;\n", args);
     deliver-results(results, #[], #f, output-info);
   end);


define-primitive-emitter
  (#"canonicalize-results",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let stream = output-info.output-info-guts-stream;
     let cluster = operation.depends-on.source-exp;
     let nfixed-leaf = operation.depends-on.dependent-next.source-exp;
     let nfixed = if (instance?(nfixed-leaf, <literal-constant>))
		    nfixed-leaf.value.literal-value;
		  else
		    error("nfixed arg to %%%%primitive canonicalize-results "
			    "isn't constant?");
		  end;
     let (bottom-name, top-name) = consume-cluster(cluster, output-info);
     format(stream, "%s = pad_cluster(%s, %s, %d);\n",
	    top-name, bottom-name, top-name, nfixed);
     let results = make(<vector>, size: nfixed + 1);
     for (index from 0 below nfixed)
       results[index] := pair(format-to-string("%s[%d]", bottom-name, index),
			      $general-rep);
     end;
     results[nfixed] := pair(format-to-string("make_rest_arg(%s + %d, %s)",
					      bottom-name, nfixed, top-name),
			     $heap-rep);
     deliver-results(defines, results, #t, output-info);
   end);

define-primitive-emitter
  (#"merge-clusters",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let cluster1 = operation.depends-on.source-exp;
     let cluster2 = operation.depends-on.dependent-next.source-exp;
     let (cluster2-bottom, cluster2-top)
       = consume-cluster(cluster2, output-info);
     let (cluster1-bottom, cluster1-top)
       = consume-cluster(cluster1, output-info);
     unless (cluster1-top = cluster2-bottom)
       error("Merging two clusters that arn't adjacent?");
     end;
     let min-values
       = cluster1.derived-type.min-values + cluster2.derived-type.min-values;
     deliver-cluster(defines, cluster1-bottom, cluster2-top,
		     make-values-ctype(make(<list>, size: min-values,
					    fill: object-ctype()),
				       object-ctype()),
		     output-info);
   end);

define-primitive-emitter
  (#"values-sequence",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let vec = extract-operands(operation, output-info, $heap-rep);
     let (cur-sp, new-sp)
       = cluster-names(output-info.output-info-cur-stack-depth);
     format(output-info.output-info-guts-stream,
	    "%s = values_sequence(%s, %s);\n", new-sp, cur-sp, vec);
     deliver-cluster(defines, cur-sp, new-sp, wild-ctype(), output-info);
   end);

define-primitive-emitter
  (#"values",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let results = make(<stretchy-vector>);
     for (dep = operation.depends-on then dep.dependent-next,
	  while: dep)
       let expr = ref-leaf($general-rep, dep.source-exp, output-info);
       add!(results, pair(expr, $general-rep));
     end;
     deliver-results(defines, results, #f, output-info);
   end);

define-primitive-emitter
  (#"initialized?",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let expr = format-to-string("(%s != NULL)",
				 extract-operands(operation, output-info,
						  $heap-rep));
     deliver-result(defines, expr, $boolean-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"allocate",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let bytes = extract-operands(operation, output-info, *long-rep*);
     deliver-result(defines, format-to-string("allocate(%s)", bytes),
		    $heap-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"make-data-word-instance",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let cclass = operation.derived-type;
     let target-rep = pick-representation(cclass, #"speed");
     let source-rep
       = pick-representation(cclass.all-slot-infos[1].slot-type, #"speed");
     unless (source-rep == target-rep
	       | (representation-data-word-member(source-rep)
		    = representation-data-word-member(target-rep)))
       error("The instance and slot representations don't match in a "
	       "data-word reference?");
     end;
     let source = extract-operands(operation, output-info, source-rep);
     deliver-result(defines, source, target-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"catch",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let func = extract-operands(operation, output-info, $heap-rep);
     let (values, sp) = cluster-names(output-info.output-info-cur-stack-depth);
     let stream = output-info.output-info-guts-stream;
     if (defines)
       format(stream, "%s = ", sp);
     end;
     let catch-defn = dylan-defn(#"catch");
     assert(instance?(catch-defn, <abstract-method-definition>));
     let catch-info = get-info-for(find-main-entry(catch-defn), output-info);
     format(stream, "save_state(%s, %s, %s);\n",
	    catch-info.function-info-name, values, func);
     if (defines)
       deliver-cluster(defines, values, sp, wild-ctype(), output-info);
     end;
   end);

define-primitive-emitter
  (#"call-out",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let stream = make(<byte-string-output-stream>);

     let func-dep = operation.depends-on;
     let func = func-dep.source-exp;
     unless (instance?(func, <literal-constant>)
	       & instance?(func.value, <literal-string>))
       error("function in call-out isn't a constant string?");
     end;
     format(stream, "%s(", func.value.literal-value);

     let res-dep = func-dep.dependent-next;
     let result-rep = rep-for-c-type(res-dep.source-exp);

     local
       method repeat (dep :: false-or(<dependency>), first? :: <boolean>)
	 if (dep)
	   unless (first?)
	     write(", ", stream);
	   end;
	   let rep = rep-for-c-type(dep.source-exp);
	   let next = dep.dependent-next;
	   format(stream, "(%s)%s",
		  rep.representation-c-type,
		  ref-leaf(rep, next.source-exp, output-info));
	   repeat(next.dependent-next, #f);
	 end;
       end;
     repeat(res-dep.dependent-next, #t);

     write(')', stream);

     spew-pending-defines(output-info);
     if (result-rep)
       deliver-result(defines, string-output-stream-string(stream),
		      result-rep, #t, output-info);
     else
       format(output-info.output-info-guts-stream, "%s;\n",
	      string-output-stream-string(stream));
       deliver-results(defines, #[], #f, output-info);
     end;
   end);

     
define method rep-for-c-type (leaf :: <leaf>)
    => rep :: false-or(<representation>);
  unless (instance?(leaf, <literal-constant>))
    error("Type spec in call-out isn't a constant?");
  end;
  let ct-value = leaf.value;
  unless (instance?(ct-value, <literal-symbol>))
    error("Type spec in call-out isn't a symbol?");
  end;
  let c-type = ct-value.literal-value;
  select (c-type)
    #"long" => *long-rep*;
    #"int" => *int-rep*;
    #"unsigned-int" => *uint-rep*;
    #"short" => *short-rep*;
    #"unsigned-short" => *ushort-rep*;
    #"char" => *byte-rep*;
    #"unsigned-char" => *ubyte-rep*;
    #"ptr" => *ptr-rep*;
    #"float" => *float-rep*;
    #"double" => *double-rep*;
    #"long-double" => *long-double-rep*;
    #"void" => #f;
  end;
end;

define-primitive-emitter
  (#"c-string",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let leaf = operation.depends-on.source-exp;
     unless (instance?(leaf, <literal-constant>))
       error("argument to c-string isn't a constant?");
     end;
     let lit = leaf.value;
     unless (instance?(lit, <literal-string>))
       error("argument to c-string isn't a string?");
     end;
     let stream = make(<byte-string-output-stream>);
     write('"', stream);
     for (char in lit.literal-value)
       let code = as(<integer>, char);
       if (char < ' ')
	 select (char)
	   '\b' => write("\\b", stream);
	   '\t' => write("\\t", stream);
	   '\n' => write("\\n", stream);
	   '\r' => write("\\r", stream);
	   otherwise =>
	     format(stream, "\\0%d%d",
		    ash(code, -3),
		    logand(code, 7));
	 end;
       elseif (char == '"' | char == '\\')
	 format(stream, "\\%c", char);
       elseif (code < 127)
	 write(char, stream);
       elseif (code < 256)
	 format(stream, "\\%d%d%d",
		ash(code, -6),
		logand(ash(code, -3), 7),
		logand(code, 7));
       else
	 error("%= can't be represented in a C string.");
       end;
     end;
     write('"', stream);
     deliver-result(defines, string-output-stream-string(stream), *ptr-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"as-boolean",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let expr = extract-operands(operation, output-info, $boolean-rep);
     deliver-result(defines, expr, $boolean-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"not",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let arg = operation.depends-on.source-exp;
     let expr
       = if (csubtype?(arg.derived-type, specifier-type(#"<boolean>")))
	   format-to-string("!%s", ref-leaf($boolean-rep, arg, output-info));
	 else
	   format-to-string("(%s == obj_False)",
			    ref-leaf($heap-rep, arg, output-info));
	 end;
     deliver-result(defines, expr, $boolean-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-=",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s == %s)", x, y),
		    $boolean-rep, #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-<",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s < %s)", x, y), $boolean-rep,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-+",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s + %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-*",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s * %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum--",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s - %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-negative",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let x = extract-operands(operation, output-info, *long-rep*);
     deliver-result(defines, format-to-string("(- %s)", x), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-floor/",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     spew-pending-defines(output-info);
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-results(defines,
		     vector(pair(format-to-string("(%s / %s)", x, y),
				 *long-rep*),
			    pair(format-to-string("(%s %% %s)", x, y),
				 *long-rep*)),
		     #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-ceiling/",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     spew-pending-defines(output-info);
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-results(defines,
		     vector(pair(format-to-string("(%s / %s)", x, y),
				 *long-rep*),
			    pair(format-to-string("(%s %% %s)", x, y),
				 *long-rep*)),
		     #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-round/",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     spew-pending-defines(output-info);
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-results(defines,
		     vector(pair(format-to-string("(%s / %s)", x, y),
				 *long-rep*),
			    pair(format-to-string("(%s %% %s)", x, y),
				 *long-rep*)),
		     #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-truncate/",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     spew-pending-defines(output-info);
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-results(defines,
		     vector(pair(format-to-string("(%s / %s)", x, y),
				 *long-rep*),
			    pair(format-to-string("(%s %% %s)", x, y),
				 *long-rep*)),
		     #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-logior",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s | %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-logxor",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s ^ %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-logand",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("(%s & %s)", x, y), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-lognot",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let x = extract-operands(operation, output-info, *long-rep*);
     deliver-result(defines, format-to-string("(~ %s)", x), *long-rep*,
		    #f, output-info);
   end);

define-primitive-emitter
  (#"fixnum-ash",
   method (defines :: false-or(<definition-site-variable>),
	   operation :: <primitive>,
	   output-info :: <output-info>)
       => ();
     let (x, y) = extract-operands(operation, output-info,
				   *long-rep*, *long-rep*);
     deliver-result(defines, format-to-string("fixnum_ash(%s, %s)", x, y),
		    *long-rep*, #f, output-info);
   end);


define method extract-operands
    (operation :: <operation>, output-info :: <output-info>,
     #rest representations)
    => (#rest str :: <string>);
  let results = make(<stretchy-vector>);
  block (return)
    for (op = operation.depends-on then op.dependent-next,
	 index from 0)
      if (index == representations.size)
	if (op)
	  error("Too many operands for %s", operation);
	else
	  return();
	end;
      else
	let rep = representations[index];
	if (rep == #"rest")
	  if (index + 2 == representations.size)
	    let rep = representations[index + 1];
	    for (op = op then op.dependent-next)
	      add!(results, ref-leaf(rep, op.source-exp, output-info));
	    end;
	    return();
	  end;
	elseif (op)
	  add!(results, ref-leaf(rep, op.source-exp, output-info));
	else
	  error("Not enough operands for %s", operation);
	end;
      end;
    end;
  end;
  apply(values, results);
end;


// Value manipulation utilities.

define method spew-pending-defines (output-info :: <output-info>) => ();
  let table = output-info.output-info-local-vars;
  let vars = key-sequence(table);
  let stream = output-info.output-info-guts-stream;
  for (var in vars)
    let (target, target-rep) = c-name-and-rep(var, output-info);
    let noise = table[var];
    emit-copy(target, target-rep, noise.head, noise.tail, output-info);
    remove-key!(table, var);
  end;
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <abstract-variable>,
			output-info :: <output-info>)
    => res :: <string>;
  let (expr, rep)
    = begin
	let info
	  = element(output-info.output-info-local-vars, leaf, default: #f);
	if (info)
	  remove-key!(output-info.output-info-local-vars, leaf);
	  values(info.head, info.tail);
	else
	  c-name-and-rep(leaf, output-info);
	end;
      end;
  conversion-expr(target-rep, expr, rep, output-info);
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <global-variable>,
			output-info :: <output-info>)
    => res :: <string>;
  let (name, rep) = c-name-and-rep(leaf, output-info);
  if (~leaf.var-info.var-defn.ct-value)
    let stream = output-info.output-info-guts-stream;
    if (rep.representation-has-bottom-value?)
      let temp = new-local(output-info);
      format(output-info.output-info-vars-stream, "%s %s;\n",
	     rep.representation-c-type, temp);
      format(stream, "if ((%s = %s) == NULL) abort();\n", temp, name);
      name := temp;
    else
      format(stream, "if (!%s_initialized) abort();\n", name);
    end;
  end;

  conversion-expr(target-rep, name, rep, output-info);
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <literal-constant>,
			output-info :: <output-info>)
    => res :: <string>;
  let (expr, rep) = c-expr-and-rep(leaf.value, target-rep, output-info);
  conversion-expr(target-rep, expr, rep, output-info);
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <definition-constant-leaf>,
			output-info :: <output-info>)
    => res :: <string>;
  let info = get-info-for(leaf.const-defn, output-info);
  conversion-expr(target-rep, info.backend-var-info-name,
		  info.backend-var-info-rep, output-info);
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <function-literal>,
			output-info :: <output-info>)
    => res :: <string>;
  conversion-expr(target-rep, "{### Function Literal}",
		  $heap-rep, output-info);
end;

define method ref-leaf (target-rep :: <representation>,
			leaf :: <uninitialized-value>,
			output-info :: <output-info>)
    => res :: <string>;
  if (target-rep == $general-rep)
    conversion-expr(target-rep, "0", $heap-rep, output-info);
  else
    "0";
  end;
end;

define method c-expr-and-rep (lit :: <ct-value>,
			      rep-hint :: <representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  let constants = output-info.output-info-constants;
  values(element(constants, lit, default: #f)
	   | (element(constants, lit) := new-root(lit, output-info)),
	 $general-rep);
end;

define method c-expr-and-rep (lit :: <literal-true>,
			      rep-hint == $boolean-rep,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values("TRUE", $boolean-rep);
end;

define method c-expr-and-rep (lit :: <literal-true>,
			      rep-hint :: <representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values("obj_True", $heap-rep);
end;

define method c-expr-and-rep (lit :: <literal-false>,
			      rep-hint == $boolean-rep,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values("FALSE", $boolean-rep);
end;

define method c-expr-and-rep (lit :: <literal-false>,
			      rep-hint :: <representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values("obj_False", $heap-rep);
end;

define method c-expr-and-rep (lit :: <literal-fixed-integer>,
			      rep-hint :: <representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values(format-to-string("%d", lit.literal-value),
	 pick-representation(dylan-value(#"<fixed-integer>"), #"speed"));
end;

define method c-expr-and-rep (lit :: <literal-single-float>,
			      rep-hint :: <immediate-representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values(float-to-string(lit.literal-value, 8),
	 pick-representation(dylan-value(#"<single-float>"), #"speed"));
end;

define method c-expr-and-rep (lit :: <literal-double-float>,
			      rep-hint :: <immediate-representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values(float-to-string(lit.literal-value, 16),
	 pick-representation(dylan-value(#"<double-float>"), #"speed"));
end;

define method c-expr-and-rep (lit :: <literal-extended-float>,
			      rep-hint :: <immediate-representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  values(float-to-string(lit.literal-value, 35),
	 pick-representation(dylan-value(#"<extended-float>"), #"speed"));
end;

define method float-to-string (value :: <float>, digits :: <fixed-integer>)
    => res :: <string>;
  float-to-string(as(<ratio>, value), digits);
end;

define method float-to-string (value :: <integer>, digits :: <fixed-integer>)
    => res :: <string>;
  float-to-string(ratio(value, 1), digits);
end;

define method float-to-string (value :: <ratio>, digits :: <fixed-integer>)
    => res :: <string>;
  if (zero?(value))
    "0.0";
  else
    let stream = make(<byte-string-output-stream>);
    if (negative?(value))
      value := -value;
      write('-', stream);
    end;
    let one = ratio(1, 1);
    let ten = ratio(10, 1);
    let one-tenth = one / ten;
    let (exponent, fraction)
      = if (value >= one)
	  for (exponent from 1,
	       fraction = value / ten then fraction / ten,
	       while: fraction >= one)
	  finally
	    values(exponent, fraction);
	  end;
	else
	  for (exponent from 0 by -1,
	       fraction = value then fraction * ten,
	       while: fraction < one-tenth)
	  finally
	    values(exponent, fraction);
	  end;
	end;
    write("0.", stream);
    let zeros = 0;
    for (count from 0 below digits,
	 until: zero?(fraction))
      let (digit, remainder) = floor(fraction * ten);
      if (zero?(digit))
	zeros := zeros + 1;
      else
	for (i from 0 below zeros)
	  write('0', stream);
	end;
	write(as(<character>, as(<fixed-integer>, digit) + 48), stream);
	zeros := 0;
      end;
      fraction := remainder;
    end;
    write('e', stream);
    print(exponent, stream);
    stream.string-output-stream-string;
  end;
end;


define method c-expr-and-rep (lit :: <literal-character>,
			      rep-hint :: <representation>,
			      output-info :: <output-info>)
    => (name :: <string>, rep :: <representation>);
  let code = as(<integer>, lit.literal-value);
  values(if (code == 0)
	   "'\\0'";
	 elseif (code == 8)
	   "'\\b'";
	 elseif (code == 9)
	   "'\\t'";
	 elseif (code == 10)
	   "'\\n'";
	 elseif (code == 13)
	   "'\\r'";
	 elseif (code < 32)
	   format-to-string("'\\%o'", code);
	 elseif (code <= 126)
	   format-to-string("'%c'", lit.literal-value);
	 else
	   format-to-string("%d", code);
	 end,
	 pick-representation(dylan-value(#"<character>"), #"speed"));
end;







define generic emit-copy
    (target :: <string>, target-rep :: <representation>,
     source :: <string>, source-rep :: <representation>,
     output-info :: <output-info>)
    => ();

define method emit-copy
    (target :: <string>, target-rep :: <general-representation>,
     source :: <string>, source-rep :: <general-representation>,
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  format(stream, "%s = %s;\n", target, source);
end;

define method emit-copy
    (target :: <string>, target-rep :: <general-representation>,
     source :: <string>, source-rep :: <data-word-representation>,
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let (proxy, proxy-rep)
    = c-expr-and-rep(make(<proxy>, for: source-rep.representation-class),
		     $heap-rep, output-info);
  format(stream, "%s.heapptr = %s;\n",
	 target, conversion-expr($heap-rep, proxy, proxy-rep, output-info));
  format(stream, "%s.dataword.%s = %s;\n",
	 target, source-rep.representation-data-word-member, source);
end;

define method emit-copy
    (target :: <string>, target-rep :: <general-representation>,
     source :: <string>, source-rep :: <c-representation>,
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let heapptr = conversion-expr($heap-rep, source, source-rep, output-info);
  format(stream, "%s.heapptr = %s;\n", target, heapptr);
  format(stream, "%s.dataword.l = 0;\n", target);
end;

define method emit-copy
    (target :: <string>, target-rep :: <c-representation>,
     source :: <string>, source-rep :: <c-representation>,
     output-info :: <output-info>)
    => ();
  let stream = output-info.output-info-guts-stream;
  let expr = conversion-expr(target-rep, source, source-rep, output-info);
  format(stream, "%s = %s;\n", target, expr);
end;


define method conversion-expr
    (target-rep :: <general-representation>,
     source :: <string>, source-rep :: <c-representation>,
     output-info :: <output-info>)
    => res :: <string>;
  if (target-rep == source-rep)
    source;
  else
    let temp = new-local(output-info);
    format(output-info.output-info-vars-stream, "%s %s;\n",
	   target-rep.representation-c-type, temp);
    emit-copy(temp, target-rep, source, source-rep, output-info);
    temp;
  end;
end;

define method conversion-expr
    (target-rep :: <c-representation>,
     source :: <string>, source-rep :: <c-representation>,
     output-info :: <output-info>)
    => res :: <string>;
  if (target-rep == source-rep)
    source;
  elseif (target-rep.representation-depth < source-rep.representation-depth)
    let to-more-general = source-rep.representation-to-more-general;
    conversion-expr(target-rep,
		    select (to-more-general)
		      #t => source;
		      #f => error("Can't happen.");
		      otherwise => format-to-string(to-more-general, source);
		    end,
		    source-rep.more-general-representation,
		    output-info);
  else
    let from-more-general = target-rep.representation-from-more-general;
    let more-general = conversion-expr(target-rep.more-general-representation,
				       source, source-rep, output-info);
    select (from-more-general)
      #t => more-general;
      #f => error("Can't happen.");
      otherwise => format-to-string(from-more-general, more-general);
    end;
  end;
end;
