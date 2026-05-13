const assert = require('assert');
const { add } = require('../src/add.js');

assert.strictEqual(add(2, 3), 5);
console.log('PASS');
