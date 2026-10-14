#!/usr/bin/env python3
"""Check the GitHub Actions workflows before they are pushed.

Three things are checked, none of which GitHub reports until a run is already in
flight -- and a run of the build workflow costs 2-3 hours:

1. The YAML parses, and the shape is one GitHub accepts: every job has either
   `runs-on` or `uses`; every step has `run` or `uses`; every `uses: ./local`
   path exists, and every input passed with `with:` is declared by the called
   workflow's `workflow_call` block.

2. Every `inputs.<name>` a workflow references is declared by one of its
   triggers.  A typo here does not fail the workflow: the expression evaluates to
   empty, and the step silently does something else.

3. Every `run:` block is syntactically valid bash (`bash -n`).  A missing `fi` in
   a step full of heredocs is easy to write and impossible to notice.

Usage:  tools/check_workflows.py [repo-root]

Requires PyYAML.  In CI: `python3 -m pip install pyyaml`.
"""

import os
import re
import subprocess
import sys
import tempfile

import yaml

BASH = os.environ.get("BASH", "bash")

# `inputs.foo`, but not `steps.inputs.foo` or a longer chain.
INPUT_REF = re.compile(r"(?<![\w.])inputs\.([A-Za-z_][A-Za-z0-9_-]*)")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def on_key(doc):
    """`on:` parses as the boolean True under YAML 1.1 -- find it either way."""
    for key in doc:
        if key is True or key == "on":
            return doc[key]
    return None


def triggers(doc):
    spec = on_key(doc)
    if isinstance(spec, str):
        return [spec]
    if isinstance(spec, list):
        return [str(t) for t in spec]
    if isinstance(spec, dict):
        return [str(t) for t in spec]
    return []


def declared_inputs(doc, trigger):
    spec = on_key(doc)
    if not isinstance(spec, dict):
        return set()
    block = spec.get(trigger)
    if not isinstance(block, dict):
        return set()
    inputs = block.get("inputs")
    return set(inputs) if isinstance(inputs, dict) else set()


def all_declared_inputs(doc):
    out = set()
    for trigger in triggers(doc):
        out |= declared_inputs(doc, trigger)
    return out


def walk_strings(node):
    """Every string in the document, with a path for error messages."""
    if isinstance(node, str):
        yield "", node
    elif isinstance(node, dict):
        for key, value in node.items():
            for path, text in walk_strings(value):
                yield "%s.%s" % (key, path) if path else str(key), text
    elif isinstance(node, list):
        for idx, value in enumerate(node):
            for path, text in walk_strings(value):
                yield "[%d]%s" % (idx, path), text


def check_bash(text, label, problems):
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False,
                                     encoding="utf-8", newline="\n") as fh:
        fh.write(text)
        path = fh.name
    try:
        proc = subprocess.run([BASH, "-n", path], capture_output=True, text=True)
        if proc.returncode != 0:
            problems.append("%s: bash -n failed:\n%s" % (label, proc.stderr.strip()))
    finally:
        os.unlink(path)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    wf_dir = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        print("!! no %s" % wf_dir)
        return 1

    problems = []
    docs = {}
    checked = 0

    paths = sorted(f for f in os.listdir(wf_dir) if f.endswith((".yml", ".yaml")))
    for name in paths:
        try:
            docs[name] = load(os.path.join(wf_dir, name))
        except yaml.YAMLError as exc:
            problems.append("%s: does not parse: %s" % (name, exc))

    for name, doc in docs.items():
        if not isinstance(doc, dict):
            problems.append("%s: top level is not a mapping" % name)
            continue
        if not triggers(doc):
            problems.append("%s: no trigger found" % name)
        jobs = doc.get("jobs")
        if not isinstance(jobs, dict) or not jobs:
            problems.append("%s: no jobs" % name)
            continue

        for job_name, job in jobs.items():
            where = "%s:%s" % (name, job_name)
            if not isinstance(job, dict):
                problems.append("%s: job is not a mapping" % where)
                continue

            if "uses" in job:
                target = job["uses"]
                if target.startswith("./"):
                    called_path = os.path.join(root, target[2:])
                    if not os.path.isfile(called_path):
                        problems.append("%s: calls %s, which does not exist" % (where, target))
                        continue
                    declared = declared_inputs(load(called_path), "workflow_call")
                    if not declared and "workflow_call" not in triggers(load(called_path)):
                        problems.append("%s: calls %s, which has no workflow_call trigger"
                                        % (where, target))
                    else:
                        undeclared = set(job.get("with") or {}) - declared
                        if undeclared:
                            problems.append("%s: passes undeclared input(s) %s to %s"
                                            % (where, sorted(undeclared), target))
                continue

            if "runs-on" not in job:
                problems.append("%s: has neither runs-on nor uses" % where)

            steps = job.get("steps")
            if not isinstance(steps, list) or not steps:
                problems.append("%s: no steps" % where)
                continue
            for idx, step in enumerate(steps):
                label = "%s step %d (%s)" % (where, idx + 1, (step or {}).get("name", "?"))
                if not isinstance(step, dict):
                    problems.append("%s: step is not a mapping" % label)
                    continue
                if "run" not in step and "uses" not in step:
                    problems.append("%s: has neither run nor uses" % label)
                script = step.get("run")
                if isinstance(script, str):
                    checked += 1
                    check_bash(script, label, problems)
                elif script is not None:
                    problems.append("%s: run is not a string (block scalar quoted wrong?)" % label)

        # An undeclared `inputs.x` is empty at run time, which reads as "the step
        # quietly did nothing" rather than as an error.
        declared = all_declared_inputs(doc)
        for path, text in walk_strings(doc):
            for ref in INPUT_REF.findall(text):
                if ref not in declared:
                    problems.append("%s: %s references undeclared input 'inputs.%s'"
                                    % (name, path, ref))

    for line in problems:
        print("!! " + line)
    print()
    print("%d workflow file(s), %d run block(s) checked, %d problem(s)"
          % (len(docs), checked, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
