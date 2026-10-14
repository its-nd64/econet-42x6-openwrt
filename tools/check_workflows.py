#!/usr/bin/env python3
"""Check the GitHub Actions workflows before they are pushed.

Four things are checked, none of which GitHub reports until the damage is done --
and a run of the build workflow costs 2-3 hours:

1. The YAML parses, and the shape is one GitHub accepts: every job has either
   `runs-on` or `uses`; every step has `run` or `uses`; every `uses: ./local`
   path exists, and every input passed with `with:` is declared by the called
   workflow's `workflow_call` block.

2. Every `inputs.<name>` a workflow references is declared by one of its
   triggers.  A typo here does not fail the workflow: the expression evaluates to
   empty, and the step silently does something else.

3. Every `run:` block is syntactically valid bash (`bash -n`).  A missing `fi` in
   a step full of heredocs is easy to write and impossible to notice.

4. Every context used in an expression is allowed where it is used, per GitHub's
   "Context availability" table.  This one is checked here precisely because
   GitHub's own report is useless: it does not fail the step or the job, it
   refuses the *file*, and the Actions tab says only "This run likely failed
   because of a workflow file issue".

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

# A context use is an identifier followed by `.` or `[` -- `github.sha`,
# `github['sha']`, `steps.pin.outputs.commit`.  `hashFiles(...)` is a function and
# is deliberately not in CONTEXTS, so it is never reported.
CONTEXTS = {
    "github", "env", "vars", "job", "jobs", "steps", "runner", "secrets",
    "strategy", "matrix", "needs", "inputs",
}
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
IDENT_DOT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*[.\[]")

STEP_CTX = {"github", "needs", "strategy", "matrix", "job", "runner", "env",
            "vars", "secrets", "steps", "inputs"}

# Which contexts GitHub allows in which key, from the "Context availability"
# table in its contexts reference.  This is worth checking locally because the
# failure mode is spectacular and unhelpful: a context used outside its list does
# not fail the step, GitHub rejects the entire workflow file, and the Actions tab
# shows only "This run likely failed because of a workflow file issue" with no
# file, no line and no job.  That is how `${{ runner.temp }}` in a job-level
# `env:` was found -- `runner` is allowed in a step's `env:` and `with:`, and not
# in the job's.
ALLOWED = {
    "workflow.env": {"github", "secrets", "inputs", "vars"},
    "workflow.run-name": {"github", "inputs", "vars"},
    "job.env": {"github", "needs", "strategy", "matrix", "vars", "secrets", "inputs"},
    "job.if": {"github", "needs", "vars", "inputs"},
    "job.name": {"github", "needs", "strategy", "matrix", "vars", "inputs"},
    "job.runs-on": {"github", "needs", "strategy", "matrix", "vars", "inputs"},
    "job.concurrency": {"github", "needs", "strategy", "matrix", "inputs", "vars"},
    "job.continue-on-error": {"github", "needs", "strategy", "vars", "matrix", "inputs"},
    "job.environment": {"github", "needs", "strategy", "matrix", "vars", "inputs"},
    "job.outputs": STEP_CTX,
    "job.with": {"github", "needs", "strategy", "matrix", "inputs", "vars"},
    "job.secrets": {"github", "needs", "strategy", "matrix", "secrets", "inputs", "vars"},
    "step.env": STEP_CTX,
    "step.if": STEP_CTX - {"secrets"},
    "step.name": STEP_CTX,
    "step.run": STEP_CTX,
    "step.with": STEP_CTX,
    "step.working-directory": STEP_CTX,
    "step.continue-on-error": STEP_CTX,
    "step.timeout-minutes": STEP_CTX,
    "call_input_default": {"github", "inputs", "vars"},
    "call_output_value": {"github", "jobs", "vars", "inputs"},
}


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


def contexts_in(text):
    """Context names used in the `${{ }}` expressions of one string."""
    found = set()
    for expr in EXPR.findall(text):
        for ident in IDENT_DOT.findall(expr):
            if ident in CONTEXTS:
                found.add(ident)
    return found


def allowed_for(path):
    """The context list for a key path like `jobs.build.steps[0].env`."""
    if path.startswith("on.workflow_call.inputs.") and path.endswith(".default"):
        return ALLOWED["call_input_default"]
    if path.startswith("on.workflow_call.outputs.") and path.endswith(".value"):
        return ALLOWED["call_output_value"]
    if path == "env" or path.startswith("env."):
        return ALLOWED["workflow.env"]
    if path == "run-name":
        return ALLOWED["workflow.run-name"]

    parts = re.split(r"[.\[]", path)
    if len(parts) < 3 or parts[0] != "jobs":
        return None
    if "steps" in parts:
        at = parts.index("steps")
        # `jobs.x.steps[0].run` -> parts[at+1] is the index, parts[at+2] the key.
        if len(parts) > at + 2 and parts[at + 1].isdigit():
            return ALLOWED.get("step." + parts[at + 2])
        return None
    return ALLOWED.get("job." + parts[2])


def walk_contexts(value, path, name, problems, counter):
    if isinstance(value, str):
        if "{{" not in value:
            return
        counter[0] += 1
        allow = allowed_for(path)
        if allow is None:
            return
        for ctx in sorted(contexts_in(value) - allow):
            problems.append(
                "%s: %s uses the '%s' context, which GitHub does not allow there "
                "(allowed: %s) -- it rejects the whole workflow file rather than "
                "failing one step" % (name, path, ctx, ", ".join(sorted(allow))))
        return
    if isinstance(value, dict):
        for key, sub in value.items():
            walk_contexts(sub, "%s.%s" % (path, key) if path else str(key),
                          name, problems, counter)
    elif isinstance(value, list):
        for idx, sub in enumerate(value):
            walk_contexts(sub, "%s[%d]" % (path, idx), name, problems, counter)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    wf_dir = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        print("!! no %s" % wf_dir)
        return 1

    problems = []
    docs = {}
    checked = 0
    exprs = 0

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

        # A context outside its allowed key makes GitHub refuse the whole file.
        counter = [0]
        walk_contexts(doc, "", name, problems, counter)
        exprs += counter[0]

    for line in problems:
        print("!! " + line)
    print()
    print("%d workflow file(s), %d run block(s) and %d expression(s) checked, "
          "%d problem(s)" % (len(docs), checked, exprs, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
