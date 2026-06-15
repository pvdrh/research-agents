#!/usr/bin/env python3
"""
_json_op.py — JSON manipulation helper cho state-store + observability.
Dùng khi máy không có jq. Bash script gọi qua: python _json_op.py <op> [args...]

Ops:
  validate <path>                    → exit 0 nếu JSON hợp lệ, 1 nếu lỗi
  get <path> <jsonpath>              → in giá trị tại jsonpath (vd .domain, .cases[0].id)
  set <path> <jsonpath> <value_json> → set giá trị (in-place), value là JSON literal
  add_step <manifest_path> <step>    → thêm step vào completed_steps, set current_step, status=RUNNING
  inc <path> <jsonpath>              → tăng số nguyên tại jsonpath thêm 1
"""
import sys, json, re

def parse_path(jp):
    """Parse .foo.bar[0].baz → list of (kind, key)."""
    parts = []
    for m in re.finditer(r'\.([A-Za-z_][\w\-]*)|\[(\d+)\]|\.\"([^\"]+)\"|\["([^"]+)"\]', jp):
        if m.group(1) is not None:
            parts.append(('key', m.group(1)))
        elif m.group(2) is not None:
            parts.append(('idx', int(m.group(2))))
        elif m.group(3) is not None:
            parts.append(('key', m.group(3)))
        elif m.group(4) is not None:
            parts.append(('key', m.group(4)))
    return parts

def get_val(data, parts):
    cur = data
    for kind, key in parts:
        if cur is None: return None
        if kind == 'key':
            cur = cur.get(key) if isinstance(cur, dict) else None
        else:
            cur = cur[key] if isinstance(cur, list) and 0 <= key < len(cur) else None
    return cur

def set_val(data, parts, value):
    if not parts:
        return value
    cur = data
    for i, (kind, key) in enumerate(parts[:-1]):
        if kind == 'key':
            if not isinstance(cur, dict): raise TypeError("expected dict")
            if key not in cur:
                # decide container type from next part
                nk = parts[i+1][0]
                cur[key] = [] if nk == 'idx' else {}
            cur = cur[key]
        else:
            cur = cur[key]
    k = parts[-1]
    if k[0] == 'key':
        cur[k[1]] = value
    else:
        cur[k[1]] = value
    return data

def main():
    if len(sys.argv) < 2:
        print("usage: _json_op.py <op> ...", file=sys.stderr); sys.exit(2)
    op = sys.argv[1]

    if op == 'validate':
        path = sys.argv[2]
        try:
            with open(path, 'r', encoding='utf-8') as f:
                json.load(f)
            sys.exit(0)
        except Exception as e:
            print(f"INVALID_JSON: {e}", file=sys.stderr); sys.exit(1)

    elif op == 'get':
        path, jp = sys.argv[2], sys.argv[3]
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        v = get_val(data, parse_path(jp))
        if v is None:
            print("null")
        elif isinstance(v, str):
            print(v)
        else:
            print(json.dumps(v, ensure_ascii=False))

    elif op == 'set':
        path, jp, val_json = sys.argv[2], sys.argv[3], sys.argv[4]
        try:
            value = json.loads(val_json)
        except json.JSONDecodeError:
            value = val_json  # treat as string literal
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        data = set_val(data, parse_path(jp), value)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    elif op == 'add_step':
        path, step = sys.argv[2], sys.argv[3]
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        steps = data.get('completed_steps', [])
        if step not in steps:
            steps.append(step)
        data['completed_steps'] = steps
        data['current_step'] = step
        data['status'] = 'RUNNING'
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    elif op == 'inc':
        path, jp = sys.argv[2], sys.argv[3]
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        parts = parse_path(jp)
        cur_val = get_val(data, parts) or 0
        data = set_val(data, parts, cur_val + 1)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(cur_val + 1)

    else:
        print(f"unknown op: {op}", file=sys.stderr); sys.exit(2)

if __name__ == '__main__':
    main()
