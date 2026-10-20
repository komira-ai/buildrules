module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  // The package's own code, for jest --coverage: the build program and the checks of the rendered tree.
  collectCoverageFrom: ['tools/**/*.ts'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
};
