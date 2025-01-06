""

load("//python/pip_install:repositories.bzl", "all_requirements")

def _construct_pypath(rctx):
    """Helper function to construct a PYTHONPATH.

    Contains entries for code in this repo as well as packages downloaded from //python/pip_install:repositories.bzl.
    This allows us to run python code inside repository rule implementations.

    Args:
        rctx: Handle to the repository_context.
    Returns: String of the PYTHONPATH.
    """

    # Get the root directory of these rules
    rules_root = rctx.path(Label("//:BUILD")).dirname
    thirdparty_roots = [
        # Includes all the external dependencies from repositories.bzl
        rctx.path(Label("@" + repo + "//:BUILD.bazel")).dirname
        for repo in all_requirements
    ]
    separator = ":" if not "windows" in rctx.os.name.lower() else ";"
    pypath = separator.join([str(p) for p in [rules_root] + thirdparty_roots])
    return pypath

def _parse_optional_attrs(rctx, args):
    """Helper function to parse common attributes of pip_repository and whl_library repository rules.

    Args:
        rctx: Handle to the rule repository context.
        args: A list of parsed args for the rule.
    Returns: Augmented args list.
    """
    extra_args = list(rctx.attr.extra_pip_args)
    for target in rctx.attr.extra_index_url_targets:
        extra_args += ["--extra-index-url", "file://" + str(rctx.path(target)).split("/index.html")[0]]
    if extra_args:
        args += [
            "--extra_pip_args",
            json.encode(struct(args = extra_args)),
        ]

    if rctx.attr.pip_data_exclude:
        args += [
            "--pip_data_exclude",
            json.encode(struct(exclude = rctx.attr.pip_data_exclude)),
        ]

    if rctx.attr.enable_implicit_namespace_pkgs:
        args.append("--enable_implicit_namespace_pkgs")
    return args

_BUILD_FILE_CONTENTS = """\
package(default_visibility = ["//visibility:public"])

# Ensure the `requirements.bzl` source can be accessed by stardoc, since users load() from it
exports_files(["requirements.bzl"])
"""

def _pip_repository_impl(rctx):
    python_interpreter = rctx.attr.python_interpreter
    if rctx.attr.python_interpreter_target != None:
        target = rctx.attr.python_interpreter_target
        python_interpreter = rctx.path(target)
    else:
        if "/" not in python_interpreter:
            python_interpreter = rctx.which(python_interpreter)
        if not python_interpreter:
            fail("python interpreter not found")

    if rctx.attr.incremental and not rctx.attr.requirements_lock:
        fail("Incremental mode requires a requirements_lock attribute be specified.")

    # We need a BUILD file to load the generated requirements.bzl
    rctx.file("BUILD.bazel", _BUILD_FILE_CONTENTS)

    pypath = _construct_pypath(rctx)

    if rctx.attr.incremental:
        args = [
            python_interpreter,
            "-m",
            "python.pip_install.parse_requirements_to_bzl",
            "--requirements_lock",
            rctx.path(rctx.attr.requirements_lock),
            # pass quiet and timeout args through to child repos.
            "--quiet",
            str(rctx.attr.quiet),
            "--timeout",
            str(rctx.attr.timeout),
        ]
        if rctx.attr.pip_platform_definitions:
            args.extend([
                "--pip_platform_definitions",
                json.encode(struct(args = {str(k): v for k, v in rctx.attr.pip_platform_definitions.items()})),
            ])
    else:
        args = [
            python_interpreter,
            "-m",
            "python.pip_install.extract_wheels",
            "--requirements",
            rctx.path(rctx.attr.requirements),
        ]

    args += ["--repo", rctx.attr.name]
    args = _parse_optional_attrs(rctx, args)

    result = rctx.execute(
        args,
        environment = {
            # Manually construct the PYTHONPATH since we cannot use the toolchain here
            "PYTHONPATH": pypath,
        },
        timeout = rctx.attr.timeout,
        quiet = rctx.attr.quiet,
    )

    if result.return_code:
        fail("rules_python failed: %s (%s)" % (result.stdout, result.stderr))

    return

common_attrs = {
    "enable_implicit_namespace_pkgs": attr.bool(
        default = False,
        doc = """
If true, disables conversion of native namespace packages into pkg-util style namespace packages. When set all py_binary
and py_test targets must specify either `legacy_create_init=False` or the global Bazel option
`--incompatible_default_to_explicit_init_py` to prevent `__init__.py` being automatically generated in every directory.

This option is required to support some packages which cannot handle the conversion to pkg-util style.
            """,
    ),
    "extra_pip_args": attr.string_list(
        doc = "Extra arguments to pass on to pip. Must not contain spaces.",
    ),
    "pip_data_exclude": attr.string_list(
        doc = "Additional data exclusion parameters to add to the pip packages BUILD file.",
    ),
    "python_interpreter": attr.string(default = "python3"),
    "python_interpreter_target": attr.label(
        allow_single_file = True,
        doc = """
If you are using a custom python interpreter built by another repository rule,
use this attribute to specify its BUILD target. This allows pip_repository to invoke
pip using the same interpreter as your toolchain. If set, takes precedence over
python_interpreter.
""",
    ),
    "quiet": attr.bool(
        default = True,
        doc = "If True, suppress printing stdout and stderr output to the terminal.",
    ),
    # 600 is documented as default here: https://docs.bazel.build/versions/master/skylark/lib/repository_ctx.html#execute
    "timeout": attr.int(
        default = 600,
        doc = "Timeout (in seconds) on the rule's execution duration.",
    ),
    "extra_index_url_targets": attr.label_list(
        default = [],
        doc = "Bazel labels for directories which should be passed to pip's --extra-index-url flag",
    )
}

pip_repository_attrs = {
    "incremental": attr.bool(
        default = False,
        doc = "Create the repository in incremental mode.",
    ),
    "requirements": attr.label(
        allow_single_file = True,
        doc = "A 'requirements.txt' pip requirements file.",
    ),
    "requirements_lock": attr.label(
        allow_single_file = True,
        doc = """
A fully resolved 'requirements.txt' pip requirement file containing the transitive set of your dependencies. If this file is passed instead
of 'requirements' no resolve will take place and pip_repository will create individual repositories for each of your dependencies so that
wheels are fetched/built only for the targets specified by 'build/run/test'.
""",
    ),
    "pip_platform_definitions": attr.label_keyed_string_dict(
        doc = """
A map of select keys to platform definitions in the form <platform>-<python_version>-<implementation>-<abi>"
        """
    )
}

pip_repository_attrs.update(**common_attrs)

pip_repository = repository_rule(
    attrs = pip_repository_attrs,
    doc = """A rule for importing `requirements.txt` dependencies into Bazel.

This rule imports a `requirements.txt` file and generates a new
`requirements.bzl` file.  This is used via the `WORKSPACE` pattern:

```python
pip_repository(
    name = "foo",
    requirements = ":requirements.txt",
)
```

You can then reference imported dependencies from your `BUILD` file with:

```python
load("@foo//:requirements.bzl", "requirement")
py_library(
    name = "bar",
    ...
    deps = [
       "//my/other:dep",
       requirement("requests"),
       requirement("numpy"),
    ],
)
```

Or alternatively:
```python
load("@foo//:requirements.bzl", "all_requirements")
py_binary(
    name = "baz",
    ...
    deps = [
       ":foo",
    ] + all_requirements,
)
```
""",
    implementation = _pip_repository_impl,
)

def _impl_whl_library(rctx):
    # pointer to parent repo so these rules rerun if the definitions in requirements.bzl change.
    _parent_repo_label = Label("@{parent}//:requirements.bzl".format(parent = rctx.attr.repo))
    pypath = _construct_pypath(rctx)
    args = [
        rctx.attr.python_interpreter,
        "-m",
        "python.pip_install.parse_requirements_to_bzl.extract_single_wheel",
        "--requirement",
        rctx.attr.requirement,
        "--repo",
        rctx.attr.repo,
    ]
    args = _parse_optional_attrs(rctx, args)
    if rctx.attr.pip_platform_definition:
        args.extend([
            "--pip_platform_definition",
            rctx.attr.pip_platform_definition,
        ])
    result = rctx.execute(
        args,
        environment = {
            # Manually construct the PYTHONPATH since we cannot use the toolchain here
            "PYTHONPATH": pypath,
        },
        quiet = rctx.attr.quiet,
        timeout = rctx.attr.timeout,
    )

    if result.return_code:
        fail("whl_library %s failed: %s (%s)" % (rctx.attr.name, result.stdout, result.stderr))

    return

whl_library_attrs = {
    "repo": attr.string(
        mandatory = True,
        doc = "Pointer to parent repo name. Used to make these rules rerun if the parent repo changes.",
    ),
    "requirement": attr.string(
        mandatory = True,
        doc = "Python requirement string describing the package to make available",
    ),
    "pip_platform_definition": attr.string(
        doc = "A pip platform definition in the form <platform>-<python_version>-<implementation>-<abi>",
    )
}

whl_library_attrs.update(**common_attrs)

whl_library = repository_rule(
    attrs = whl_library_attrs,
    doc = """
Download and extracts a single wheel based into a bazel repo based on the requirement string passed in.
Instantiated from pip_repository and inherits config options from there.""",
    implementation = _impl_whl_library,
)

_PLATFORM_ALIAS_TMPL = """
alias(
    name = "pkg",
    actual = select({select_items}),
    visibility = ["//visibility:public"],
)
"""

def _impl_platform_alias(rctx):
    rctx.file(
        "BUILD",
        content = _PLATFORM_ALIAS_TMPL.format(
            select_items = rctx.attr.select_items
        ),
        executable = False,
    )

platform_alias = repository_rule(
    attrs = {
        "select_items": attr.string_dict()
    },
    implementation = _impl_platform_alias,
    doc = """
An internal rule used to create an alias for a pip package for the appropriate platform."""
)
