const { defineConfig } = require('eslint/config');
const expo = require('eslint-config-expo/flat');
module.exports = defineConfig([expo, { rules: { 'react-hooks/set-state-in-effect': 'warn' }, ignores: ['dist/**', 'test-results/**', 'src/api/schema.d.ts'] }]);
