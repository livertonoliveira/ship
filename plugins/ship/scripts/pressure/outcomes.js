'use strict';

function exitCodeFor(outcomes) {
  const list = Array.isArray(outcomes) ? outcomes : [outcomes];
  const hasMalformedCase = list.some((outcome) => outcome?.malformed === true);
  return hasMalformedCase ? 1 : 0;
}

module.exports = { exitCodeFor };
