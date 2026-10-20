const fs = require('fs');
const { greeting } = require('./hello.js');
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/hello.txt', greeting() + '\n');
