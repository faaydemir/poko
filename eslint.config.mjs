import js from '@eslint/js';
import globals from 'globals';
export default [
  {ignores: ['node_modules/', 'dist/', '.build/']},
  js.configs.recommended,
  {languageOptions: {ecmaVersion: 2023, sourceType: 'module', globals: globals.node},
   rules: {'preserve-caught-error': 'off', 'no-unused-vars': ['error', {args: 'after-used', argsIgnorePattern: '^_', caughtErrors: 'none'}], 'no-empty': ['error', {allowEmptyCatch: true}]}}
];
