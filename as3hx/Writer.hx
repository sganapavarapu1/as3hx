/*
 * Copyright (c) 2008-2011, Franco Ponticelli and Russell Weir
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package as3hx;

using Lambda;

import as3hx.As3;
import haxe.io.Output;

enum BlockEnd {
	None;
	Semi;
	Ret;
}

typedef CaseDef = {
	var vals : Array<Expr>;
	var el : Array<Expr>;
}

/**
 * ...
 * @author Franco Ponticelli
 * @author Russell Weir
 */
class Writer
{
	var lvl : Int;
	var o : Output;
	var cfg : Config;
	var warnings : Hash<Bool>; // warning->isError
	var loopIncrements : Array<Expr>;
	var varCount : Int; // vars added for ESwitch or EFor initialization
	var isInterface : Bool; // set if current class is an interface
	var context : Hash<String>;
	var contextStack : Array<Hash<String>>;
	var inArrayAccess : Bool;

	public function new(config:Config)
	{
		this.lvl = 0;
		this.cfg = config;
		this.varCount = 0;
		this.context = new Hash();
		this.contextStack = new Array();
		this.inArrayAccess = false;
	}

	/**
	 * Opens a new context for variable typing
	 **/
	function openContext() {
		var c = new Hash();
		for(k in context.keys())
			c.set(k, context.get(k));
		contextStack.push(context);
		context = c;
	}

	/**
	 * Closes the current variable typing copntext
	 **/
	function closeContext() {
		context = contextStack.pop();
	}

	function formatComment(s:String, isBlock:Bool):String {
		if(!isBlock)
			return s;
		var r = ~/^[\t]+/mg;
        return StringTools.ltrim(r.replace(s,indent()));
	}

	function writeComments(comments : Array<Expr>) {
		for(c in comments) {
			switch(c) {
			case ECommented(s,b,t,e):
				if(e != null)
					throw "Unexpected " + e + " in comments";
				writeNL(indent() + formatComment(s,b));
			default:
				throw "Unexpected " + c + " in header";
			}
		}
	}

	function writePackage(pack : Array<String>)
	{
		if (pack.length > 0)
		{
			writeLine("package " + properCaseA(pack,false).join(".") + ";");
			writeLine();
		}
	}
	
	function writeImports(imports : Array<Array<String>>)
	{
		if (imports.length > 0)
		{
			for(i in imports)
				writeLine("import " + properCaseA(i,true).join(".") + ";");
			writeLine();
		}
	}

	function writeDefinitions(defs : Array<Definition>)
	{
		for(d in defs)
			writeDefinition(d);
	}
	
	function writeDefinition(def : Definition)
	{
		switch(def)
		{
			case CDef( c ):
				writeClassDef(c);
			case FDef( f ):
				writeFunctionDef(f);
			case NDef( n ):
				writeNamespaceDef(n);
		}
	}

	function writeMetaData(data:Array<Expr>) {
		if(data == null)
			return;
		for(d in data) {
			writeIndent();
			switch(d) {
			case EMeta(_):
				writeExpr(d);
			case ECommented(s,b,t,e):
				writeExpr(d);
			default:
				throw "Unexpected " + d;
			}
		}
	}

	function writeClassDef(c : ClassDef)
	{
		writeMetaData(c.meta);

		var buf = new StringBuf();
		this.isInterface = c.isInterface;
		buf.add(c.isInterface ? "interface " : "class ");
		buf.add(properCase(c.name,true));
		
		var parents = [];
		if (null != c.extend) {
			parents.push((isInterface ? "implements " : "extends ") + tstring(c.extend));
		}
		for (i in c.implement)
			parents.push("implements " + tstring(i));
		if(parents.length > 0)
			buf.add(" " + parents.join(", "));
		buf.add(openb());
		writeLine(buf.toString());
		lvl++;
		
		// process properties
		writeProperties(c);
		writeNL();
	
		// process fields
		writeFields(c);

		//TODO c.inits
		// a list of TId(ClassName),TSemicolon pairs that is typically
		// at the end of a class
		//writeInits(c);
		
		lvl--;
		writeLine(closeb());
		writeNL();
	}
	
	function writeProperties(c : ClassDef)
	{
		var p = [];
		var h = new Hash();
		var getOrCreateProperty = function(name, t, stat)
		{
			var property = h.get(name);
			if (null == property)
			{
				property = {
					name : name,
					get : "never",
					set : "never",
					ret : t,
					sta : stat,
					pub : false,
				};
				p.push(property);
				h.set(name, property);
				context.set(name, tstring(t, true));
			}
			return property;
		}
		for (field in c.fields)
		{
			switch(field.kind)
			{
				case FFun( f ):
					if (isOverride(field.kwds))
						continue;
					if (isGetter(field.kwds))
					{
						var property = getOrCreateProperty(field.name, f.ret, isStatic(field.kwds));
						if (isPublic(field.kwds))
						{
							property.get = cfg.makeGetterName(field.name);
							property.pub = true;
						} else {
							property.get = cfg.makeGetterName(field.name);
						}
					} else if (isSetter(field.kwds)) {
						var property = getOrCreateProperty(field.name, f.args[0].t, isStatic(field.kwds));
						if (isPublic(field.kwds))
						{
							property.set = cfg.makeSetterName(field.name);
							property.pub = true;
						} else {
							property.set = cfg.makeSetterName(field.name);
						}
					}
				default:
					continue;
			}
		}
		if(cfg.getterSetterStyle == "haxe" || cfg.getterSetterStyle == "combined") {
			for (property in p)
			{
				writeIndent();
				if(cfg.getterSetterStyle == "combined")
					write("#if !flash ");
				if (property.sta)
					write("static ");
				if (property.pub)
					write("public ");
				write("var " + property.name + "(" + property.get + ", " + property.set + ")");
				writeVarType(property.ret);
				if(cfg.getterSetterStyle == "combined")
					writeNL("; #end");
				else
					writeNL(";");
				context.set(property.name, tstring(property.ret, false));
			}
		}
	}
	
	function writeFields(c : ClassDef)
	{
		for (field in c.fields)
			writeField(field, c);
		if(c.isInterface)
			return;
		// check if there is no constructor, since as3 allows class
		// variables to be initialized outside the constructor, we
		// will have to create a constructor here

		// test for member var with initialization
		if(!Lambda.exists(c.fields,
			function(field:ClassField) {
				switch(field.kind)
				{
					case FVar(_, val):
						if (null != val && !isStatic(field.kwds))
							return true;
					default:
				}
				return false;
			}
		))
			return;
			
		if(!Lambda.exists(c.fields,
			function(field:ClassField) {
				switch(field.kind) {
					case FFun( f ):
						if (field.name == c.name)
							return true;
					default:
				}
				return false;
			}
		))
		{
			addWarning("Required constructor was added for member var initialization");
			writeNL();
			writeIndent();
			writeConstructor({
				args : [],
				varArgs : null,
				ret : null,
				expr : EBlock([]),
			}, c);
		}
	}
	
	function writeField(field : ClassField, c : ClassDef)
	{
		var isGet : Bool = isGetter(field.kwds);
		var isSet : Bool = isSetter(field.kwds);
		var isFun : Bool = switch(field.kind) {case FFun(_): true; default: false;};

		writeMetaData(field.meta);
		var start = function(name:String, isFlashNative:Bool=false) {
			if((isGet || isSet) && cfg.getterSetterStyle == "combined") {
				writeNL(isFlashNative ? "#if flash" : "#else");
				//writeNL("");
			}
			writeIndent();

			if(isFlashNative) {
				if(isGet) {
					write("@:getter(");
					write(name);
					write(") ");
				} else if(isSet) {
					write("@:setter(");
					write(name);
					write(") ");
				}
				if((isGet || isSet) && isProtected(field.kwds)) {
					write("@:protected ");
				}
			}
			if (isOverride(field.kwds))
				write((isFlashNative && (isGet || isSet)) ? "" : "override ");
			if (isStatic(field.kwds))
				write("static ");
			if (isPublic(field.kwds))
				write("public ");
			if (isConst(field.kwds) && isStatic(field.kwds))
				write("inline ");
		}
		switch(field.kind)
		{
			case FVar( t, val ):
				start(field.name, false);
				write("var " + field.name);
				writeVarType(t);
				context.set(field.name, tstring(t, false));
				if(val != null && isStatic(field.kwds)) {
					write(" = ");
					writeExpr(val);
				}
				writeNL(";");
			case FFun( f ):
				if (field.name == c.name)
				{
					start("new", false);
					writeConstructor(f, c);
				} else {
					var ret = f.ret;
					var name = if (isGetter(field.kwds)) {
						cfg.makeGetterName(field.name); //"get" + ucfirst(field.name);
					} else if (isSetter(field.kwds)) {
						ret = f.args[0].t;
						cfg.makeSetterName(field.name); //"set" + ucfirst(field.name);
					} else {
						field.name;
					}
					if(isGetter(field.kwds) || isSetter(field.kwds)) {
						// write flash native
						if( cfg.getterSetterStyle == "flash" || cfg.getterSetterStyle == "combined") {
							start(field.name, true);
							writeFunction(f, isGetter(field.kwds), isSetter(field.kwds), true, name, ret);
						}
						// write haxe version
						if( cfg.getterSetterStyle == "haxe" || cfg.getterSetterStyle == "combined") {
							start(field.name, false);
							writeFunction(f, isGetter(field.kwds), isSetter(field.kwds), false, name, ret);
						}
						if(cfg.getterSetterStyle == "combined") {
							writeNL("#end");
							writeNL("");
						}
					} else {
						start(name, false);
						writeFunction(f, isGetter(field.kwds), isSetter(field.kwds), false, name, ret);
					}
				}
				if(!isInterface) writeNL();
			case FComment:
				//writeComments(field.meta);
		}
	}
	
	function writeArgs(args : Array<{ name : String, t : Null<T>, val : Null<Expr> }>)
	{
		var fst = null;
		for (arg in args)
		{
			if (null == fst)
			{
				fst = arg;
			} else {
				write(", ");
			}
			write(arg.name);
			writeVarType(arg.t);
			context.set(arg.name, tstring(arg.t, false));
			if(arg.val != null) {
				write(" = ");
				writeExpr(arg.val);
			}
		}
		return fst;
	}
	
	function writeConstructor(f : Function, c : ClassDef)
	{
		write("function new(");
		writeArgs(f.args);
		write(")");
		var es = [];
		switch(f.expr)
		{
			case EBlock(e):
				// inject instance field values
				for (field in c.fields)
				{
					switch(field.kind)
					{
						case FVar(_, val):
							if (null != val && !isStatic(field.kwds))
							{
								var expr = EBinop("=", EIdent(field.name), val);
								es.push(expr);
							}
						default:
							//
					}
				}
				es = es.concat(e);
			default:
				es.push(f.expr);
		}
		writeExpr(EBlock(es));
	}
	
	function writeFunction(f : Function, isGetter:Bool, isSetter:Bool, isNative:Bool, name : Null<String>, ?ret : Null<T>)
	{
		write("function");
		if(null != name)
			write(" " + name);
		write("(");
		var fst = writeArgs(f.args);
		write(")");

		// return type
		if (null == ret)
			ret = f.ret;
		if(isNative) {
			if(isGetter)
				writeVarType(ret, "{}", true);
			if(isSetter)
				writeVarType(null, "Void", true);
		}
		else
			writeVarType(ret,null,false);

		// ensure the function body is in a block
		var es = [];
		if(f.expr != null) {
			switch(f.expr)
			{
				case EBlock(e):
					es = es.concat(e);
				default:
					es.push(f.expr);
			}
		}
		// haxe setters must return the provided type
		if(isSetter && !isNative && f.args.length == 1) {
			es.push(EReturn(EIdent(f.args[0].name)));
		}
		writeExpr(EBlock(es));
	}

	function writeLoop(incrs:Array<Expr>, f:Void->Void) {
		var old = loopIncrements;
		loopIncrements = incrs.slice(0);
		f();
		loopIncrements = old;
	}
	
	static function ucfirst(s : String)
	{
		return s.substr(0, 1).toUpperCase() + s.substr(1);
	}
	
	function writeVarType(t : Null<T>, ?alt : String, isNativeGetSet:Bool=false)
	{
		if (null == t)
		{
			if (null != alt)
				write(" : " + alt);
			return;
		}
		write(" : " + tstring(t,isNativeGetSet));
	}

	function writeInits(c : ClassDef) {
		if(c.inits == null || c.inits.length == 0)
			return;
		writeNL("");
		writeIndent();
		writeNL("static function __init__() {");
		lvl++;
		for(e in c.inits) {
			writeIndent();
			writeExpr(e);
			writeNL(";");
		}
		lvl--;
		writeIndent();
		writeNL("}");
	}
	
	function getConst(c : Const)
	{
		switch(c)
		{
			case CInt( v ), CFloat( v ):
				return v;
			case CString( s ):
				return quote(s);
		}
	}

	function getExprType(e:Expr, descend:Bool=true) : String {
		switch(e) {
			case EField(e2, f):
				if(descend)
					return getExprType(e2);
			case EIdent(s):
				return context.get(s);
			case EArray(n, i):
				if(descend)
					return getExprType(n);
			default:
		}
		return null;
	}

	/**
	 * Returns the base variable from expressions like xml.user
	 * EField(EIdent(xml),user)
	 **/
	function getBaseVar(e:Expr) : String {
		switch(e) {
			case EField(e2, f):
				return getExprType(e2);
			case EIdent(s):
				return s;
			default:
		}
		throw "Unexpected";
	}

	function typeExpr(e:Expr) : String {
		switch(e) {
			case EIdent(s):
				return context.get(s);
			default:
		}
		return null;
	}

	public static inline function getModifiedIdent(cfg : Config, s : String) {
		return switch(s) {
			case "string": 		"String";
			case "int":			"Int";
			case "uint":		cfg.uintToInt ? "Int" : "UInt";
			case "number":		"Float";
			case "array":		"Array";
			case "boolean","Boolean":"Bool";
			case "Function":	cfg.functionToDynamic ? "Dynamic" : s;
			case "Object":		"Dynamic";
			case "undefined":	"null";
			case "Error":		cfg.mapFlClasses ? "flash.errors.Error" : s;
			case "XML":			cfg.mapFlClasses ? "flash.xml.XML" : "FastXML";
			case "XMLList":		cfg.mapFlClasses ? "flash.xml.XMLList" : "Array<FastXML>";
			case "QName":		cfg.mapFlClasses ? "flash.utils.QName" : s;
			default: s;
		};
	}

	function writeModifiedIdent(s : String) {
		write (getModifiedIdent(cfg, s));
	}

	/**
	 * Write an expression
	 * @return if the block requires a terminating ;
	 **/
	function writeExpr(expr : Expr) : BlockEnd
	{
		if(cfg.debugExpr)
			write(" /* " + Std.string(expr) + " */ ");

		if(expr == null) return None;
		var rv = Semi;
		switch(expr)
		{
			case EConst( c ):
				write(getConst(c));
			case EIdent( v ):
				write(v);
			case EVars( vars ):
				for (i in 0...vars.length)
				{
					if (i > 0) {
						writeNL(";");
						writeIndent("");
					}
					var v = vars[i];
					context.set(v.name, tstring(v.t, false));
					write("var " + v.name);
					writeVarType(v.t);
					if (null != v.val)
					{
						write(" = ");
						writeExpr(v.val);
					}
				}
			case EParent( e ):
				write("(");
				writeExpr(e);
				write(")");
			case EBlock( e ):
				if(!isInterface) {
					openContext();
					write(openb());
					lvl++;
					writeNL();
					for (ex in e)
					{
						writeIndent();
						writeFinish(writeExpr(ex));
					}
					lvl--;
					write(closeb());
					closeContext();
					writeNL();
					rv = Ret;
				} else { writeNL(";"); rv = None; }
			case EField( e, f ):
				//write("/* EField ("+Std.string(e)+","+Std.string(f)+") " + Std.string(getExprType(e, false)) + "  */ ");
				//[EField(EArray(EIdent(user3),EConst(CInt(0))),name)])
				var old = inArrayAccess;
				if(getExprType(e, false) == "FastXML") {
					writeExpr(e);
					if(inArrayAccess)
						write(".nodes." + f);
					else
						write(".node." + f + ".innerData");
				}
				else if(getExprType(e, true) == "Array<FastXML>") {
					writeExpr(e);
					write(".node");
					write("." + f + ".innerData");
				}
				else {
					switch(e) {
						case EField(e2, f2):
							if(getExprType(e2, false) == "FastXML")
								inArrayAccess = true;
						default:
					}
					writeExpr(e);
					write("." + f);
				}
				inArrayAccess = old;
			case EBinop( op, e1, e2 ):
				if(op == "as") {
					switch(e2) {
					case EIdent(s):
						switch(s) {
						case "string":
							write("Std.string(");
							writeExpr(e1);
							write(")");
						case "int":
							write("Std.int(");
							writeExpr(e1);
							write(") /** AS3HX WARNING check type **/");
							addWarning("as int",false);
						case "number":
							write("Std.parseFloat(");
							writeExpr(e1);
							write(") /** AS3HX WARNING check type **/");
							addWarning("as number",false);
						case "array":
							write("try cast(");
							writeExpr(e1);
							write(", Array</*AS3HX WARNING no type*/>) catch(e:Dynamic) null");
							addWarning("as array", true);
						case "Class":
							addWarning("as Class",true);
							write("Type.getClass(");
							writeExpr(e1);
							write(")");
						default:
							write("try cast(");
							writeExpr(e1);
							write(", ");
							switch(e2) {
							case EIdent(s):
								writeModifiedIdent(s);
							default:
								writeExpr(e2);
							}
							write(") catch(e:Dynamic) null");
						}
					case EField(_):
						write("try cast(");
						writeExpr(e1);
						write(", ");
						switch(e2) {
						case EIdent(s):
							writeModifiedIdent(s);
						default:
							writeExpr(e2);
						}
						write(") catch(e:Dynamic) null");
					default:
						throw "Unexpected " + Std.string(e2);
					}
				}
				else if(op == "is") {
					write("Std.is(");
					writeExpr(e1);
					write(", ");
					switch(e2) {
					case EIdent(s):
						writeModifiedIdent(s);
					default:
						writeExpr(e2);
					}
					write(")");
				}
				else if(op == "in") {
					write("Lambda.has(");
					writeExpr(e2);
					write(", ");
					writeExpr(e1);
					write(")");
				}
				else {
					switch(e1) {
					case EIdent(s):
						writeModifiedIdent(s);
					default:
						writeExpr(e1);
					}
					write(" " + op + " ");
					switch(e2) {
					case EIdent(s):
						writeModifiedIdent(s);
					default:
						writeExpr(e2);
					}
				}
			case EUnop( op, prefix, e ):
				if (prefix)
				{
					write(op);
					writeExpr(e);
				} else {
					writeExpr(e);
					write(op);
				}
			case ECall( e, params ):
				var handled = false;
				if(cfg.guessCasts && params.length == 1) {
					switch(e) {
					case EIdent(n):
						var c = n.charCodeAt(0);
						if(n.indexOf(".") == -1 && c>=65 && c<=90) {
							handled = true;
							switch(n) {
							case "Int":
								write("Std.int(");
								writeExpr(params[0]);
								write(")");
							case "Number":
								write("Std.parseFloat(");
								writeExpr(params[0]);
								write(") /* AS3HX WARNING check type */");
							case "String":
								write("Std.string(");
								writeExpr(params[0]);
								write(")");
							default:
								write("cast((");
								writeExpr(params[0]);
								write("), ");
								write(n + ")");
							}
						}
						// other cases that come up as ECall
						switch(n) {
						case "isNaN":
							write("Math.isNaN(");
							writeExpr(params[0]);
							write(")");
							handled = true;
						}
					case EVector(t):
						handled = true;
						if(cfg.vectorToArray) {
							write("cast ");
							writeExpr(params[0]);
						} else {
							write("Vector.ofArray(cast ");
							writeExpr(params[0]);
							write(")");
						}
					default:
					}
				}
				if(!handled) {
					writeExpr(e);
					write("(");
					for (i in 0...params.length)
					{
						if (i > 0)
							write(", ");
						writeExpr(params[i]);
					}
					write(")");
				}
			case EIf( cond, e1, e2 ):
				write("if(");
				writeExpr(cond);
				write(") ");
				switch(e1) {
					case EBlock(_):
					default:
						lvl++;
						writeNL();
						write(indent());
						lvl--;
				}
				writeExpr(e1);
				if (e2 != null)
				{
					writeNL();
					writeIndent("else ");
					rv = writeExpr(e2);
				} else {
					rv = switch(e1) {
 						case EObject(_): Ret;
						case EBlock(_): None;
						case EIf(_,_,_): Semi;
						case EReturn(_): Semi;
						default: Semi; 
					}
				}
			case ETernary( cond, e1, e2 ):
				write("(");
				writeExpr(cond);
				write(") ? ");
				writeExpr(e1);
				write(" : ");
				writeExpr(e2);
			case EWhile( cond, e, doWhile ):
				if (doWhile)
				{
					write("do");
					writeExpr(e);
					write("while(");
					writeExpr(cond);
					write(")");
				} else {
					write("while(");
					writeExpr(cond);
					write(")");
					rv = writeExpr(e);
				}
			case EFor( inits, conds, incrs, e ):
				openContext();
				for (init in inits)
				{
					writeExpr(init);
					writeNL(";");
				}
				writeIndent();
				write("while(");
				for (i in 0...conds.length)
				{
					if (i > 0)
						write(" && ");
					writeExpr(conds[i]);
				}
				write(")");
				var es = [];
				
				switch(e)
				{
					case EBlock(ex):
						es = ex.copy();
					default:
						es.push(e);
				}
				
				for (incr in incrs) {
					es.push(incr);
				}
				writeLoop(incrs, function() { writeExpr(EBlock(es)); });
				closeContext();
				rv = None;
			case EForEach( ev, e, block ):
				openContext();
				var varName = null;
				write("for(");
				switch(ev) {
					case EVars(vars):
						if(vars.length == 1 && vars[0].val == null) {
							write(vars[0].name);
							varName = vars[0].name;
						} else {
							writeExpr(ev);
						}
					default:
						writeExpr(ev);
				}
				write(" in ");
				var old = inArrayAccess;
				inArrayAccess = true;
				writeExpr(e);
				inArrayAccess = old;
				var t = getExprType(e);
				if((t == "FastXML" || t == "Array<FastXML>" )&& varName != null) {
					context.set(varName, "FastXML");
				} else {
					write("/* AS3HX WARNING could not determine type for var: " + varName + " exp: " + e + " type: " +getExprType(e)+ "*/");
				}
				write(")");
				switch(block) {
					case EBlock(_):
					default:
						lvl++;
						writeNL();
						writeIndent();
						lvl--;
				}
				rv = writeExpr(block);
				closeContext();
			case EForIn( ev, e, block ):
				openContext();
				write("for(");
				switch(ev) {
					case EVars(vars):
						if(vars.length == 1 && vars[0].val == null) {
							write(vars[0].name);
							context.set(vars[0].name, "String");
						} else {
							writeExpr(ev);
						}
					default:
						writeExpr(ev);
				}
				write(" in Reflect.fields(");
				writeExpr(e);
				write("))");
				rv = writeExpr(block);
				closeContext();
			case EBreak( label ):
				write("break");
			case EContinue:
				if(loopIncrements != null && loopIncrements.length > 0) {
					var exp = loopIncrements.slice(0);
					exp.push(EIdent("continue"));
					rv = writeExpr(EBlock(exp));
				} else {
					write("continue");
				}
			case EFunction( f, name ):
				writeFunction(f, false, false, false, name);
			case EReturn( e ):
				write("return");
				if (null != e)
				{
					write(" ");
					writeExpr(e);
				}
			case EArray( e, index ):
				var old = inArrayAccess;
				inArrayAccess = true;
				writeExpr(e);
				inArrayAccess = old;
				write("[");
				writeExpr(index); // TODO, not integers
				write("]");
				
			case EArrayDecl( e ):
				write("[");
				for (i in 0...e.length)
				{
					if (i > 0)
						write(", ");
					writeExpr(e[i]);
				}
				write("]");
			case ENew( t, params ):
				write("new " + tstring(t) + "(");
				var out = true;
				// prevent params when converting vector to array
				switch(t) {
				case TVector(_): out = !cfg.vectorToArray;
				default:
				}
				if(out) {
					for (i in 0...params.length)
					{
						if (i > 0)
							write(", ");
						writeExpr(params[i]);
					}
				}
				write(")");
			case EThrow( e ):
				write("throw ");
				writeExpr(e);
			case ETry( e, catches ):
				write("try");
				writeExpr(e);
				for (c in catches)
				{
					writeIndent("catch(" + c.name);
					writeVarType(c.t, "Dynamic");
					write(")");
					rv = writeExpr(c.e);
				}
			case EObject( fl ):
				if (fl.length == 0)
				{
					write("{ }");
				} else {
					writeNL("{");
					lvl++;
					for (i in 0...fl.length)
					{
						var field = fl[i];
						writeIndent(field.name + " : ");
						writeExpr(field.e);
						writeNL(i > 0 || fl.length > 1 ? "," : "");
					}
					lvl--;
					writeNL();
					writeIndent("}");
				}
			case ERegexp( str, opts ):
				write('new EReg('+eregQuote(str)+', "'+opts+'")');
			case ESwitch( e, cases, def):
				var newCases : Array<CaseDef> = new Array();
				var writeTestVar = false;
				var testVar = switch(e) {
				case EParent(ex):
					switch(ex) { case EIdent(i): i; default: null; }
				default:
					null;
				}
				if(testVar == null) {
					writeTestVar = true;
					testVar = "_sw"+(varCount++)+"_";
				}
				if(def != null) {
					switch(def[def.length-1]) {
						case EBreak(lbl):
							if(lbl == null) 
								def.pop(); // remove break
						default:
					}
				}
				newCases = loopCases(cases.slice(0), def == null ? null : def.slice(0), testVar, newCases);

				if(writeTestVar) {
					write("var " + testVar + " = ");
					writeFinish(writeExpr(e));
					writeIndent("");
				}
				write("switch(" + testVar + ")" + openb());
				writeNL();
				for(c in newCases) {
					writeIndent("case ");
					for(i in 0...c.vals.length) {
						write(i>0 ? ", " : "");
						writeExpr(c.vals[i]);
					}
					writeNL(":");
					lvl++;
					for (i in 0...c.el.length)
					{
						writeIndent();
						writeFinish(writeExpr(c.el[i]));
					}
					lvl--;
				}
				if (def != null)
				{
					writeLine("default:");
					lvl++;
					for (i in 0...def.length)
					{
						writeIndent();
						writeFinish(writeExpr(def[i]));
					}
					lvl--;
				}
				write(closeb());
				rv = Ret;
			case EVector( t ):
				// Vector.<T> call
				// _buffers = Vector.<MyType>([inst1,inst2]);
				// t is TPath([inst1,inst2]), which should have been handled in ECall 
				write(tstring(t));
				addWarning("Vector.<T>", true);
			case EE4XAttr( e1, e2 ):
				// e1.@e2
				writeExpr(e1);
				trace(e1);
				write(".att.");
				writeExpr(e2);
				addWarning("EE4X");
			case EE4XFilter( e1, e2 ):
				// e1.(weight > 300) innerData search
				writeE4XFilterExpr(e1, e2, false);
			case EE4XFilterAttr( e1, e2 ):
				// e1.(@user_id == 3) attribute search
				writeE4XFilterExpr(e1, e2, true);
			case EXML( s ):
				//write("new flash.xml.XML(" + quote(s) + ")");
				write("FastXML.parse(" + quote(s) + ")");
				addWarning("EXML");
			case ELabel( name ):
				addWarning("Unhandled ELabel("+name+")", true);
			case ECommented(s,b,t,ex):
				if(t)
					writeExpr(ex);
				write(formatComment(s,b));
				if(!b) {
					writeNL("");
					if(!t)
						write(indent());
				} 	
				if(!t) 
					writeExpr(ex);

				if (ex == null) rv = Ret;
			case EMeta(m):
				write("@:meta("+m.name+"(");
				var first = true;
				for(arg in m.args) {
					if(!first)
						write(",");
					first = false;
					if(arg.name != null)
						write(arg.name + "=");
					else
						write("name=");
					writeExpr(arg.val);
				}
				writeNL("))");
			case ETypeof(e):
				switch(e) {
				case EBinop(op, e1, e2):
					writeExpr(ETypeof(e1));
					write(" " + op + " ");
					writeExpr(e2);
				//case EIdent(id):
				default:
					write("as3hx.Compat.typeof(");
					writeExpr(e);
					write(")");
				}
				addWarning("ETypeof");
		}
		return rv;
	}

	// as3
	// xml.user.(@user_id == 3);
	// to haxe
	//XMLFast.filterNodes(xml.nodes.user,
	//	function(x) {
	//		if(x.att.user_id == 3)
	//			return true;
	//		return false;
	//	});
	// e1.(@user_id == 3) attribute search
	function writeE4XFilterExpr(e1, e2, isAttribute : Bool) {
		var fxmlfield : String = (isAttribute ? "att" : "node");
		write("FastXML.filterNodes(");
		var n = getBaseVar(e1);    // make sure it's set to FastXML in the
		context.set(n, "FastXML"); // current context
		var old = inArrayAccess;
		inArrayAccess = true;
		writeExpr(e1); // ensure 'nodes' vs. 'node'
		inArrayAccess = old;
		write(", function(x) {\n");
		lvl++;
		writeIndent("if(");// + wrapper + "x.att.");
		writeExpr(rebuildE4XExpr(e2, fxmlfield));
		writeNL(")");
		lvl++;
		writeLine("return true;");
		lvl--;
		writeLine("return false;\n");
		lvl--;
		writeIndent("})");
	}

	function rebuildE4XExpr(e:Expr,field:String) : Expr {
		var rv : Expr = null;
		/* EBinop(==,EIdent(user_id),EConst(CInt(3))) */
		switch(e) {
		case EBinop(op, e2, e3): // e2 should be EIdent()
			var id : String = "x." + field + ".";
			switch(e2) {
				case EIdent(i):
					id += i;
				default:
					throw "Unexpected " + e2;
			}
			if(field == "node")
				id += ".innerData";
			var r1 = EIdent(id);
			var r2 : Expr = null;
			switch(e3) {
			case EConst(c):
				switch(c) {
					case CInt(_), CFloat(_):
						rv = EBinop(op,ECall(EField(EIdent("Std"),"parseFloat"), [r1]),e3);
					default:
				}
			default:
			}
		default:
			throw "Unexpected " + e;
		}
		return rv;
	}

	function addWarning(type,isError=false) {
		warnings.set(type, isError);
	}
	
	static function quote(s : String)
	{
		return '"' + StringTools.replace(s, '"', '\\"') + '"';
	}

	static function eregQuote(s : String)
	{
		return "'" + StringTools.replace(s, "\\", "\\\\") + "'";
	}
	
	function isOverride(kwds : Array<String>)
	{
		return Lambda.has(kwds, "override");
	}
	
	function isStatic(kwds : Array<String>)
	{
		return Lambda.has(kwds, "static");
	}
	
	function isPublic(kwds : Array<String>)
	{
		return Lambda.has(kwds, "public");
	}
	
	function isProtected(kwds : Array<String>)
	{
		return Lambda.has(kwds, "protected");
	}

	function isGetter(kwds : Array<String>)
	{
		return Lambda.has(kwds, "get");
	}
	
	function isSetter(kwds : Array<String>)
	{
		return Lambda.has(kwds, "set");
	}

	function isConst(kwds : Array<String>)
	{
		return Lambda.has(kwds, "const");
	}
	
	function tstring(t : T, isNativeGetSet:Bool=false)
	{
		if(t == null)
			return null;
		switch(t)
		{
			case TStar:
				return "Dynamic";
			case TVector( t ):
				return cfg.vectorToArray ? "Array<" + tstring(t) + ">" : "Vector<" + tstring(t) + ">";
			case TPath( p ):
				var c = p.join(".");
				return switch(c)
				{
					case "Array"	: "Array<Dynamic>";
					case "Boolean"	: "Bool";
					case "Class"	: "Class<Dynamic>";
					case "int"		: "Int";
					case "Number"	: "Float";
					case "uint"		: cfg.uintToInt ? "Int" : "UInt";
					case "void"		: "Void";
					case "Function"	: cfg.functionToDynamic ? "Dynamic" : c;
					case "Object"	: isNativeGetSet ? "{}" : "Dynamic";
					default			: properCase(c,true);
				}
			case TComplex(e):
				return buffer(function() { writeExpr(e); });
		}
	}
	
	function writeFunctionDef(f : FunctionDef)
	{
		trace("****** not complete *******");
		trace(f);
		trace("***************************");
	}
	
	function writeNamespaceDef(n : NamespaceDef)
	{
		
	}

	function loopCases(cases : Array<{ val : Expr, el : Array<Expr> }>, def: Null<Array<Expr>>, testVar:String, out:Array<CaseDef>) {
		var c : { val : Expr, el : Array<Expr> } = cases.pop();
		if(c == null)
			return out;

		var outCase = {
			vals: new Array(),
			el : new Array()
		};

		var falls = false;
		if(c.el == null || c.el.length == 0) {
			falls = true;
		} else {
			switch(c.el[c.el.length-1]) {
			case EBreak(lbl):
				if(lbl == null) 
					c.el.pop(); // remove break
				falls = false;
			default:
				falls = true;
			}
		}

		// if it's a fallthough, we have to add the cases val to the
		// next out case, and wrap the Expr list in another ESwitch
		if(falls && out.length > 0) {
			var nextCase = out[0];
			nextCase.vals.unshift(c.val);
			var el = c.el.slice(0);
			if(el.length > 0) {
				el.push(EBreak(null));
				nextCase.el.unshift(ESwitch(EParent(EIdent(testVar)), [{val:c.val, el: el}], null));
			}
		} else { 
			outCase.vals.push(c .val);
			for(e in c.el)
				outCase.el.push(e);
			if(falls) {
				// last case before default, add default code since this case has no break
				if(def != null)
					for(e in def)
						outCase.el.push(e);
			}
			out.unshift(outCase);
		} 
		out = loopCases(cases, null, testVar, out);
		return out;
	}

	function openb()
	{
		if (cfg.bracesOnNewLine)
			return cfg.newlineChars + indent() + "{";
		else
			return " {";
	}
	
	function closeb()
	{
		return indent() + "}";
	}
	
	function write(s : String)
	{
		o.writeString(s);
	}
	
	function writeIndent(s = "")
	{
		write(indent() + s);
	}
	
	function writeLine(s = "")
	{
		write(indent() + s + cfg.newlineChars);
	}
	
	function writeNL(s = "")
	{
		write(s + cfg.newlineChars);
	}

	function writeFinish(cond) {
		switch(cond) {
		case None:
		case Semi: writeNL(";");
		case Ret: writeNL("");
		}
	}

	/**
	 * Switches output to a string accumulator
	 * @return contents of buffer after calling f()
	 **/
	function buffer(f:Void->Void) : String {
		var old = o;
		o = new haxe.io.BytesOutput();
		f();
		var rv = untyped o.getBytes().toString();
		o = old;
		return rv;
	}
	
	function indent()
	{
		var b = [];
		for (i in 0...lvl)
			b.push(cfg.indentChars);
		return b.join("");
	}
	
	public function process(program : Program, writer : Output)
	{
		this.warnings = new Hash();
		this.o = writer;
		writeComments(program.header);
		writePackage(program.pack);
		writeImports(program.imports);
		writeDefinitions(program.defs);
		writeComments(program.footer);
		return this.warnings;
	}

	/**
	 * This method outputs each warning and the associated affected files.
	 * By doing it this way, it becomes easy to see all the places a specific
	 * warning is affecting, so that the porter can more easily determine
	 * the fix.
	 **/
	public static function showWarnings(allWarnings : Hash<Hash<Bool>>) {
		var wke : Hash<Array<String>> = new Hash(); // warning->files
		for(filename in allWarnings.keys()) {
			for(errname in allWarnings.get(filename).keys()) {
				var a = wke.get(errname);
				if(a == null) a = [];
				a.push(filename);
				wke.set(errname,a);
			}
		}
		var println = neko.Lib.println;
		for(warn in wke.keys()) {
			var a = wke.get(warn);
			if(a.length > 0) {
				switch(warn) {
				case "EE4X": println("ERROR: The following files have xml notation that will need porting. See http://haxe.org/doc/advanced/xml_fast");
				case "EXML": println("WARNING: There is XML that may not have translated correctly in these files:");
				case "Vector.<T>": println("FATAL: These files have a Vector.<T> call, which was not handled. Check versus source file!");
				case "ETypeof": println("WARNING: These files use flash 'typeof'. as3hx.Compat is required, or recode http://haxe.org/doc/cross/reflect");
				case "as Class": println("WARNING: These files casted using 'obj as Class', which may produce incorrect code");
				case "as number", "as int": println("WARNING: "+warn+" casts in these files");
				case "as array": println("ERROR: type must be determined for 'as array' cast for:");
				default: println("WARNING: " + warn);
				}
				for(f in a)
					println("\t"+f);
			}
		}
	}

	public static function properCase(pkg:String, hasClassName:Bool) {
		return properCaseA(pkg.split("."), hasClassName).join(".");
	}

	public static function properCaseA(path:Array<String>, hasClassName:Bool) {
		var p = [];
		for(i in 0...path.length) {
			if(hasClassName && i == path.length - 1)
				p[i] = removeUnderscores(path[i]);
			else
				p[i] = path[i].toLowerCase();
		} 
		if(hasClassName) {
			var f = p[p.length-1];
			var o = "";
			for(i in 0...f.length) {
				var c = f.charCodeAt(i);
				if(i == 0)
					o += String.fromCharCode(c).toUpperCase();
				else
					o += String.fromCharCode(c);
			}
			p[p.length-1] = o;
		}
		return p;
	}

	public static function removeUnderscores(id : String) {
		return id.split("_").map( 
			function (v:String) return v.length > 0 ? v.charAt(0).toUpperCase() + v.substr(1) : ""
		).array().join("");
	}
	
}
