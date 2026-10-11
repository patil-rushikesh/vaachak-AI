import { execFileSync } from "node:child_process";
import { expect, it } from "vitest";

it("navigation query parsing preserves values and bounds malformed URL decoding", () => {
  // A separate process prevents a decoder regression from hanging the test runner.
  const result = execFileSync(process.execPath, ["-e", `
    const assert = require('node:assert/strict');
    const query = require('query-string');
    assert.equal(query.parse('name=Asha%20Rao').name, 'Asha Rao');
    assert.equal(query.parse('greeting=%E0%A4%A8%E0%A4%AE%E0%A4%B8%E0%A5%8D%E0%A4%A4%E0%A5%87').greeting, 'नमस्ते');
    assert.deepEqual(query.parse('tag=a&tag=b').tag, ['a', 'b']);
    for (const value of ['%C0'.repeat(1000), '%E0%A4'.repeat(1000), '%FF%FE'.repeat(1000)]) {
      assert.equal(typeof query.parse('value=' + value).value, 'string');
    }
    process.stdout.write('ok');
  `], { encoding: "utf8", timeout: 3000 });
  expect(result).toBe("ok");
});
