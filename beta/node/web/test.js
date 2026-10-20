const assert = require('assert');
const { greeting } = require('./hello.js');
assert.strictEqual(greeting(), 'Hello, world!');
