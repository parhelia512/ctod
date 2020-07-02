module ctod.translate;

import ctod;
import tree_sitter.api, tree_sitter.wrapper;
import std.format;
import std.stdio;

private immutable moduleHeader = "/// Translated from C to D
module %s;

extern(C): @nogc: nothrow:
";

private immutable hasVersion = q{
private template HasVersion(string versionId) {
	mixin("version("~versionId~") {enum HasVersion = true;} else {enum HasVersion = false;}");
}
};

///
string translateFile(string source, string moduleName) {
	Node* root = parseCtree(source);
	assert(root);
	auto ctx = TranslationContext("foo.c", source);
	translateNode(ctx, *root);
	string result = format(moduleHeader, moduleName);
	if (ctx.needsHasVersion) {
		result ~= hasVersion;
	}
	result ~=root.output;
	return result;
}

/// What the C macro is for
enum MacroType {
	none, // und
	manifestConstant, // #define three 3
	inlineFunc, // #define SQR(x) (x*x)
	versionId, // #ifdef _WIN32_
	staticIf,
}

/// A single .c file
package struct TranslationContext {

	string fileName;
	string source;

	string moduleName;

	bool needsHasVersion = false; // HasVersion(string) template is needed

	// context
	const(char)[] parentType = "";

	/// global variables and function declarations
	string[string] symbolTable;
	string[string] localSymbolTable;

	this(string fileName, string source) {
		this.fileName = fileName;
		this.source = source;
	}
}

///
void translateNode(ref TranslationContext ctu, ref Node node) {
	if (tryTranslatePreprocessor(ctu, node)) {
		return;
	}
	if (tryTranslateDeclaration(ctu, node)) {
		return;
	}
	if (tryTranslateMisc(ctu, node)) {
		return;
	}

	foreach(ref c; node.children) {
		translateNode(ctu, c);
	}
	/+
	return "";
	//writefln("> %20s: %s", node.type, "..."); // nodeSource(node, )
	+/
}

bool tryTranslateMisc(ref TranslationContext ctu, ref Node node) {
	switch (node.type) {
		case "concatenated_string":
			// "a" "b" "c" => "a"~"b"~"c"
			bool first = true;
			foreach(ref c; node.children) {
				if (c.type == "string_literal") {
					if (first) {
						first = false;
					} else {
						c.prepend("~ ");
					}
				}
			}
			return true;
		case "primitive_type":
			if (string s = replacePrimitiveType(node.source)) {
				node.replace(s);
				return true;
			}
			return false;
		case "null":
			return node.replace("null");

		case "type_definition":
			// Decl[] decls = parseDecls(ctu, *c);

			// typedef struct X X; => uncomment, not applicable to D
			if (auto typeField = node.childField("type")) {
				if (auto structId = typeField.childField("name")) {
					if (typeField.type == "struct_specifier") {
						if (auto bodyField = typeField.childField("body")) {

						} else if (auto declaratorField = node.childField("declarator")) {
							if (declaratorField.type == "type_identifier") {
								if (declaratorField.source == structId.source) {
									node.prepend("/+");
									node.append("+/");
									return true;
								}
							}
						}
					}

				}
			}
			break;
		case "typedef":
			return node.replace("alias");
		case "sizeof_expression":
			if (auto typeNode = node.childField("type")) {
				// sizeof(short) => (short).sizeof
				translateNode(ctu, *typeNode);
				node.replace("" ~ typeNode.output ~ ".sizeof");
			} else if (auto valueNode = node.childField("value")) {
				translateNode(ctu, *valueNode);
				// `sizeof short` => `short.sizeof`
				if (valueNode.type == "identifier") {
					node.replace("" ~ valueNode.output ~ ".sizeof");
				} else {
					// sizeof(3) => typeof(3).sizeof
					// brackets may be redundant
					node.replace("typeof(" ~ valueNode.output ~ ").sizeof");
				}
			}
			break;

		case "->":
			return node.replace(".");
		case "cast_expression":
			if (auto c = node.firstChildType("(")) {
				c.replace("cast(");
			}
			if (auto c = node.childField("type")) {
				Decl[] decls = parseDecls(ctu, *c); //tryTranslateDeclaration();
				if (decls.length == 1) {
					c.replace(decls[0].toString());
				}
			}
			return false;
		case "struct_specifier":
			// todo: I want to remove the trialing ;, but it seems to be a hidden node
			break;
		case "translation_unit":
			// these are trailing ; after union and struct definitions.
			// we don't want them in D
			foreach(ref c; node.children) {
				if (c.type == ";") {
					c.replace("");
				}
			}
			break;
		default: break;
	}
	return false;
}
