import ts from "typescript";
import fs from "node:fs";
import path from "node:path";
const rows = [];
function scan(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) scan(p);
    else if (p.endsWith(".tsx")) parse(p);
  }
}
function parse(file) {
  const text = fs.readFileSync(file, "utf8");
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  function visit(node) {
    if (ts.isJsxSelfClosingElement(node) || ts.isJsxOpeningElement(node)) {
      const tag = node.tagName.getText(source);
      const props = node.attributes.properties;
      if (
        [
          "Button",
          "Confirm",
          "Field",
          "Switch",
          "Pressable",
          "Audio",
          "Speak",
        ].includes(tag) ||
        props.some((p) => p.name?.getText(source) === "onPress")
      ) {
        const label = props.find((p) =>
          ["title", "label", "accessibilityLabel"].includes(
            p.name?.getText(source),
          ),
        );
        rows.push({
          file,
          line: source.getLineAndCharacterOfPosition(node.getStart()).line + 1,
          tag,
          label: label?.initializer?.getText(source) || "(dynamic/child text)",
          conditional: props.some(
            (p) => p.name?.getText(source) === "disabled",
          ),
          status: "requires evidence",
        });
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
}
scan("src");
parse("App.tsx");
fs.writeFileSync(
  "../../docs/verification/frontend/control-inventory.json",
  JSON.stringify(rows, null, 2) + "\n",
);
console.log(
  `${rows.length} control declarations inventoried (dynamic options require multiple states).`,
);
