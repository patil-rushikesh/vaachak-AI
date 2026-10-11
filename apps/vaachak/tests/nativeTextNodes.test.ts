import { it, expect } from "vitest";
import ts from "typescript";
import fs from "node:fs";
import path from "node:path";
it("never renders string expressions directly inside native layout containers", () => {
  const issues: string[] = [];
  for (const name of fs
    .readdirSync("src/features")
    .filter((n) => n.endsWith(".tsx"))) {
    const file = path.join("src/features", name),
      source = ts.createSourceFile(
        file,
        fs.readFileSync(file, "utf8"),
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.TSX,
      );
    const visit = (node: ts.Node) => {
      if (
        ts.isJsxElement(node) &&
        ["View", "Row", "Page", "Card"].includes(
          node.openingElement.tagName.getText(source),
        )
      )
        for (const child of node.children)
          if (
            ts.isJsxExpression(child) &&
            child.expression &&
            ts.isStringLiteral(child.expression) &&
            child.expression.text.length
          )
            issues.push(
              `${name}:${source.getLineAndCharacterOfPosition(child.getStart()).line + 1}`,
            );
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  expect(issues).toEqual([]);
});
