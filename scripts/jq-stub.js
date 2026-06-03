#!/usr/bin/env node
// Minimal jq subset for ceo-cron.sh / ceo-config.sh tests.
// Handles the actual query patterns used — no full jq DSL.
'use strict';

const fs = require('fs');

// --- parse args ---
const argv = process.argv.slice(2);
let rawOutput = false, compactOutput = false, exitStatus = false, nullInput = false;
let filter = null;
let inputFiles = [];
const argVars = {};
let slurp = false;

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--') { continue; }
  if (a === '-r') { rawOutput = true; continue; }
  if (a === '-c') { compactOutput = true; continue; }
  if (a === '-e') { exitStatus = true; continue; }
  if (a === '-n') { nullInput = true; continue; }
  if (a === '-s') { slurp = true; continue; }
  if (a === '-rc' || a === '-cr') { rawOutput = true; compactOutput = true; continue; }
  if (a === '-re' || a === '-er') { rawOutput = true; exitStatus = true; continue; }
  if (a === '--arg') { argVars[argv[++i]] = argv[++i]; continue; }
  if (a === '--argjson') { argVars[argv[++i]] = JSON.parse(argv[++i]); continue; }
  if (a.startsWith('-') && a.length > 1 && !a.startsWith('--')) {
    // Combined flags like -rce
    for (const ch of a.slice(1)) {
      if (ch === 'r') rawOutput = true;
      else if (ch === 'c') compactOutput = true;
      else if (ch === 'e') exitStatus = true;
      else if (ch === 'n') nullInput = true;
      else if (ch === 's') slurp = true;
    }
    continue;
  }
  if (filter === null) { filter = a; continue; }
  inputFiles.push(a);
}
if (filter === null) filter = '.';

// --- eval ---
function evalJq(obj, expr, vars) {
  expr = expr.trim();

  // empty literal
  if (expr === 'empty') return [];

  // null literal
  if (expr === 'null') return [null];

  // boolean literals
  if (expr === 'true') return [true];
  if (expr === 'false') return [false];

  // number literal
  if (/^-?\d+(\.\d+)?$/.test(expr)) return [parseFloat(expr)];

  // string literal "..."
  if (/^"[^"]*"$/.test(expr)) return [expr.slice(1, -1)];

  // identity
  if (expr === '.') return [obj];

  // has("key")
  const hasMatch = expr.match(/^has\("([^"]+)"\)$/);
  if (hasMatch) {
    if (obj === null || typeof obj !== 'object') return [false];
    return [Object.prototype.hasOwnProperty.call(obj, hasMatch[1])];
  }

  // type
  if (expr === 'type') {
    if (obj === null) return ['null'];
    if (Array.isArray(obj)) return ['array'];
    return [typeof obj];
  }

  // floor
  if (expr === 'floor') {
    return [typeof obj === 'number' ? Math.floor(obj) : obj];
  }

  // length
  if (expr === 'length') {
    if (typeof obj === 'string') return [obj.length];
    if (Array.isArray(obj)) return [obj.length];
    if (obj !== null && typeof obj === 'object') return [Object.keys(obj).length];
    return [0];
  }

  // keys
  if (expr === 'keys') {
    if (obj !== null && typeof obj === 'object' && !Array.isArray(obj)) {
      return [Object.keys(obj).sort()];
    }
    return [[]];
  }

  // .[] (iterate values)
  if (expr === '.[]') {
    if (Array.isArray(obj)) return obj;
    if (obj !== null && typeof obj === 'object') return Object.values(obj);
    return [];
  }

  // .[]? (iterate values, silent)
  if (expr === '.[]?') {
    if (Array.isArray(obj)) return obj;
    if (obj !== null && typeof obj === 'object') return Object.values(obj);
    return [];
  }

  // not
  if (expr === 'not') return [!obj];

  // @base64d — not needed, skip
  // @base64 — not needed, skip

  // if A then B else C end  (parse before pipe — if has its own `|` scope)
  const ifMatch = expr.match(/^if\s+([\s\S]+?)\s+then\s+([\s\S]+?)\s+else\s+([\s\S]+?)\s+end$/);
  if (ifMatch) {
    const cond = evalJq(obj, ifMatch[1].trim(), vars);
    const condVal = cond.length > 0 ? cond[0] : null;
    if (condVal && condVal !== false && condVal !== null) {
      return evalJq(obj, ifMatch[2].trim(), vars);
    } else {
      return evalJq(obj, ifMatch[3].trim(), vars);
    }
  }

  // A | B (pipe — lowest precedence, split first)
  const pipeIdx = findTopLevelPipe(expr);
  if (pipeIdx >= 0) {
    const leftExpr = expr.slice(0, pipeIdx).trim();
    const rightExpr = expr.slice(pipeIdx + 1).trim();
    const intermediates = evalJqMulti(obj, leftExpr, vars);
    const results = [];
    for (const mid of intermediates) {
      results.push(...evalJq(mid, rightExpr, vars));
    }
    return results;
  }

  // A // B (alternative)
  const altIdx = findTopLevelAlt(expr);
  if (altIdx >= 0) {
    const left = evalJqMulti(obj, expr.slice(0, altIdx).trim(), vars);
    const lv = left.length > 0 ? left[0] : null;
    if (lv !== null && lv !== false && lv !== undefined && lv !== '') {
      return [lv];
    }
    return evalJqMulti(obj, expr.slice(altIdx + 2).trim(), vars);
  }

  // A or B
  const orMatch = splitOnTopLevelKeyword(expr, 'or');
  if (orMatch) {
    const left = evalJq(obj, orMatch[0], vars);
    const leftVal = left.length > 0 ? left[0] : null;
    if (leftVal && leftVal !== false) return [true];
    const right = evalJq(obj, orMatch[1], vars);
    const rightVal = right.length > 0 ? right[0] : null;
    return [!!rightVal];
  }

  // A and B
  const andMatch = splitOnTopLevelKeyword(expr, 'and');
  if (andMatch) {
    const left = evalJq(obj, andMatch[0], vars);
    const leftVal = left.length > 0 ? left[0] : null;
    if (!leftVal || leftVal === false) return [false];
    const right = evalJq(obj, andMatch[1], vars);
    const rightVal = right.length > 0 ? right[0] : null;
    return [!!rightVal];
  }

  // A == B
  const eqIdx = findTopLevelOp(expr, '==');
  if (eqIdx >= 0) {
    const left = evalJq(obj, expr.slice(0, eqIdx).trim(), vars);
    const right = evalJq(obj, expr.slice(eqIdx + 2).trim(), vars);
    const lv = left.length > 0 ? left[0] : null;
    const rv = right.length > 0 ? right[0] : null;
    return [lv === rv];
  }

  // A != B
  const neIdx = findTopLevelOp(expr, '!=');
  if (neIdx >= 0) {
    const left = evalJq(obj, expr.slice(0, neIdx).trim(), vars);
    const right = evalJq(obj, expr.slice(neIdx + 2).trim(), vars);
    const lv = left.length > 0 ? left[0] : null;
    const rv = right.length > 0 ? right[0] : null;
    return [lv !== rv];
  }

  // A >= B
  const geIdx = findTopLevelOp(expr, '>=');
  if (geIdx >= 0) {
    const left = evalJq(obj, expr.slice(0, geIdx).trim(), vars);
    const right = evalJq(obj, expr.slice(geIdx + 2).trim(), vars);
    const lv = left.length > 0 ? left[0] : null;
    const rv = right.length > 0 ? right[0] : null;
    return [lv >= rv];
  }

  // .field[]? or .field[]
  const iterFieldMatch = expr.match(/^\.(\w+)\[\]\??$/);
  if (iterFieldMatch) {
    const val = obj ? obj[iterFieldMatch[1]] : null;
    if (!Array.isArray(val)) return [];
    return val;
  }

  // .field[N]
  const indexFieldMatch = expr.match(/^\.(\w+)\[(\d+)\]$/);
  if (indexFieldMatch) {
    const val = obj ? obj[indexFieldMatch[1]] : null;
    if (!Array.isArray(val)) return [null];
    return [val[parseInt(indexFieldMatch[2])] !== undefined ? val[parseInt(indexFieldMatch[2])] : null];
  }

  // select(expr)
  const selectMatch = expr.match(/^select\(([\s\S]+)\)$/);
  if (selectMatch) {
    const cond = evalJq(obj, selectMatch[1].trim(), vars);
    const condVal = cond.length > 0 ? cond[0] : null;
    if (condVal && condVal !== false) return [obj];
    return [];
  }

  // index($var) or index("string")
  const indexMatch = expr.match(/^index\((\$[\w]+|"[^"]*")\)$/);
  if (indexMatch) {
    let needle;
    if (indexMatch[1].startsWith('$')) {
      needle = vars[indexMatch[1].slice(1)];
    } else {
      needle = indexMatch[1].slice(1, -1);
    }
    if (!Array.isArray(obj)) return [null];
    const idx = obj.indexOf(needle);
    return [idx >= 0 ? idx : null];
  }

  // $varname
  if (/^\$[\w]+$/.test(expr)) {
    const varName = expr.slice(1);
    return [varName in argVars ? argVars[varName] : null];
  }

  // .field (simple field access)
  const fieldMatch = expr.match(/^\.(\w+(?:\.\w+)*)$/);
  if (fieldMatch) {
    const parts = fieldMatch[1].split('.');
    let val = obj;
    for (const p of parts) {
      if (val === null || typeof val !== 'object') { val = null; break; }
      val = val[p] !== undefined ? val[p] : null;
    }
    return [val];
  }

  // ."field" (quoted field)
  const quotedFieldMatch = expr.match(/^\."([^"]+)"$/);
  if (quotedFieldMatch) {
    const val = obj ? obj[quotedFieldMatch[1]] : null;
    return [val !== undefined ? val : null];
  }

  // (expr) — parenthesized
  if (expr.startsWith('(') && expr.endsWith(')')) {
    return evalJq(obj, expr.slice(1, -1).trim(), vars);
  }

  return [null];
}

function evalJqMulti(obj, expr, vars) {
  return evalJq(obj, expr, vars);
}

// Split on top-level keyword (and/or), respecting parens
function splitOnTopLevelKeyword(expr, kw) {
  let depth = 0;
  let inStr = false;
  const re = new RegExp(`\\b${kw}\\b`);
  for (let i = 0; i < expr.length; i++) {
    const c = expr[i];
    if (c === '"' && !inStr) inStr = true;
    else if (c === '"' && inStr) inStr = false;
    if (!inStr) {
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
    }
    if (!inStr && depth === 0) {
      const slice = expr.slice(i);
      const m = slice.match(new RegExp(`^\\s+${kw}\\s+`));
      if (m) {
        return [expr.slice(0, i).trim(), expr.slice(i + m[0].length).trim()];
      }
    }
  }
  return null;
}

// Find top-level binary operator position (==, !=, >=)
function findTopLevelOp(expr, op) {
  let depth = 0, inStr = false;
  for (let i = 0; i <= expr.length - op.length; i++) {
    const c = expr[i];
    if (c === '"' && !inStr) inStr = true;
    else if (c === '"' && inStr) inStr = false;
    if (!inStr) {
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      if (depth === 0 && expr.slice(i, i + op.length) === op) {
        // Make sure it's not part of a longer op
        const before = i > 0 ? expr[i - 1] : ' ';
        const after = expr[i + op.length] || ' ';
        if (op === '==' && (before === '!' || before === '<' || before === '>')) continue;
        if (op === '>=' && before === '<') continue;
        return i;
      }
    }
  }
  return -1;
}

// Find top-level // (alternative) — skip //
function findTopLevelAlt(expr) {
  let depth = 0, inStr = false;
  for (let i = 0; i <= expr.length - 2; i++) {
    const c = expr[i];
    if (c === '"' && !inStr) inStr = true;
    else if (c === '"' && inStr) inStr = false;
    if (!inStr) {
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      if (depth === 0 && expr[i] === '/' && expr[i + 1] === '/') {
        return i;
      }
    }
  }
  return -1;
}

// Find top-level | (pipe)
function findTopLevelPipe(expr) {
  let depth = 0, inStr = false;
  for (let i = 0; i < expr.length; i++) {
    const c = expr[i];
    if (c === '"' && !inStr) inStr = true;
    else if (c === '"' && inStr) inStr = false;
    if (!inStr) {
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      if (depth === 0 && c === '|' && (i === 0 || expr[i - 1] !== '|') && (i + 1 >= expr.length || expr[i + 1] !== '|')) {
        return i;
      }
    }
  }
  return -1;
}

function outputVal(v) {
  if (v === null || v === undefined) {
    if (exitStatus) process.exit(1);
    process.stdout.write('null\n');
    return;
  }
  if (typeof v === 'boolean') {
    if (exitStatus && !v) process.exit(1);
    process.stdout.write((v ? 'true' : 'false') + '\n');
    return;
  }
  if (rawOutput && typeof v === 'string') {
    if (v === 'null') { if (exitStatus) process.exit(1); }
    process.stdout.write(v + '\n');
    return;
  }
  if (compactOutput) {
    process.stdout.write(JSON.stringify(v) + '\n');
    return;
  }
  process.stdout.write(JSON.stringify(v, null, rawOutput ? 0 : 2) + '\n');
}

function run(inputData) {
  let data;
  try { data = JSON.parse(inputData.trim() || 'null'); } catch (e) { process.exit(1); }
  const results = evalJq(data, filter, argVars);
  for (const r of results) outputVal(r);
}

if (inputFiles.length > 0) {
  for (const f of inputFiles) {
    try { run(fs.readFileSync(f, 'utf8')); } catch (e) { process.exit(1); }
  }
} else if (nullInput) {
  run('null');
} else {
  const chunks = [];
  process.stdin.on('data', d => chunks.push(d));
  process.stdin.on('end', () => run(Buffer.concat(chunks).toString('utf8')));
}
