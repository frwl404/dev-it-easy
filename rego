#!/usr/bin/env python3

"""
rego is a single-file tool, which is aimed to simplify/unify/speedup
development workflow for any repository/project.
It is not important for rego if your project is written
in Python/Go/Rust/C++/Java or something else, rego can
work with any project in the same way.

Author: anton.chivkunov@gmail.com
Official repo: https://github.com/frwl404/rego
"""

import argparse
import os
import os.path
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import (
    Any,
    Dict,
    List,
    Mapping,
    Optional,
    Set,
    Tuple,
    Union,
)

# We use .toml format of config files, but parsers for this format
# might be not available in old python versions (only in 3.11 tomllib
# was included into Python itself). Since we are not going to have any
# requirements from target systems (apart from Python itself),
# we will try import few well-known libs in hope that target system
# have something installed. In case if nothing found, we will try to
# use our-own implementation (quite limited in functionality however).
try:
    # Starting from Python 3.11 it is available together with Python.
    import tomllib
except ModuleNotFoundError:
    try:
        # On significant part of setups we have pip installed and pip
        # have tomli inside of it (unfortunately in private module).
        import pip._vendor.tomli as tomllib
    except ModuleNotFoundError:
        try:
            # Small chance that target system has tomli installed directly
            import tomli as tomllib
        except ModuleNotFoundError:
            # And only if nothing at all is available, we will try to use
            # our own, very simplified parser, which has a lot of restrictions
            class _SimplifiedTomlParser:
                def load(self, file):
                    return TomlParser().load(file)

            tomllib = _SimplifiedTomlParser()


TOOL_NAME = os.path.basename(__file__)
TOOL_RELATIVE_PATH = f"./{TOOL_NAME}"
TOOL_ABS_PATH = f"{os.path.abspath(__file__)}"
TOOL_DIR = os.path.dirname(TOOL_ABS_PATH).lstrip("/")
REPO_NAME = TOOL_DIR

DEFAULT_CFG_PATH = f"{TOOL_RELATIVE_PATH}.toml"


INITIAL_CONFIG_CONTENT = """
# This is auto-generated file, which contains recommended set of commands and examples.
# To make it working for you project, please update configuration.
# For real-word examples, please check https://github.com/frwl404/rego
# You can find all details, needed for updating it to your needs in:
# https://github.com/frwl404/rego/blob/main/docs/CONFIG

#######################################################
# Examples of commands
#######################################################
[[commands]]
name = "test"
description = "runs unit tests"
# OPTIONALLY, you can specify actions, which you want to perform before the main command.
# For python projects, you may want to activate venv here.
before = ["echo This is just an exampe", "echo You should configure your tests here"]
# Actual command to run (can be single command, or script).
# You can pass additional options to this executable via console (see 'examples' section)
execute = "echo ALL TESTS PASSED"
# OPTIONALLY, you can specify actions, which you want to perfrom after the main command
# to do cleanup
after =["echo done > /dev/null"]
# OPTIONALLY, you can specify examples of command usage.
# if missing, ./rego will auto generate single example.
examples = ["tests --cov -vv", "tests --last-failed"]
## OPTIONALLY you can specify container, in which command should be executed by defaut.
## Container must be defined in the same file.
## It can be overwritten, or set from CLI as well.
# docker_container = "alpine"
## OPTIONALLY, you can specify 'docker run' options, which should be used at command execution.
## See official docker documentation: https://docs.docker.com/reference/cli/docker/container/run/
# docker_run_options = "-it -v .:/app -w /app"

[[commands]]
name = "build"
description = "builds the project"
execute = "echo Buld is running"
after = ["echo done"]
#docker_container = "alpine"
#docker_run_options = "-it -v .:/app -w /app"

[[commands]]
name = "shell"
description = "debug container by running shell in interactive mode (keep container running)"
execute = "/bin/sh"
docker_container = "alpine"
docker_run_options = "-it -v .:/app -w /app"

[[commands]]
name = "pre-commit"
description = "quick checks/fixes of code formatting (ruff/mypy)"
execute = "echo Ruff is formatting the code"
after = ["echo Formating completed"]
#execute = "scripts/pre_commit.sh"
#docker_container = "alpine"
#docker_run_options = "-v .:/app -w /app"

[[commands]]
name = "update-deps"
description = "updates dependencies, used in project, to the latest versions"
execute = "echo Often it is pain, but if you will script it and put here, it will be super easy"
#execute = "scripts/update-requirements.sh"
#docker_container = "alpine"
#docker_run_options = "-v .:/app -w /app"

#######################################################
# Examples of containers
#######################################################

# 1.1) Single container, based on image from repo.
# This is the simplest case, you should just specify target image:
[[docker_containers]]
name = "alpine"
docker_image = "alpine:3.14"

## 1.2) Single container, based on your local Docker file:
#[[docker_containers]]
#name = "python39"
## docker_file_path may be relative to './rego' file (recommended way),
## or absolute, what is also supported, but this is not what you usually need.
#docker_file_path = "containers/python39/Dockerfile"
## OPTIONALLY, you can provide build options, which you want
## to be used for building of your image, see:
## https://docs.docker.com/reference/cli/docker/buildx/build/
#docker_build_options = "--tag img-defined-by-docker-file"
#
## 2) Composition of multiple containers, based on your docker-compose.yml file
## This is probably most common (and also most complicated case)
#[[docker_containers]]
#name = "app-with-db"
## Compose file path may be relative to './rego' file (recommended way),
## or absolute, what is also supported, but this is not what you usually need.
#docker_compose_file_path = "docker-compose.yml"
## You should specify those service in compose file, whose container should
## be used to run commands in
#docker_compose_service = "app"
## OPTIONALLY you can specify options, which should be passed to docker-compose
## to run your command. For details see official docker documentation:
## https://docs.docker.com/reference/cli/docker/compose/
#docker_compose_options = "--all-resources"
"""


class Logger:
    def __init__(self):
        self._debug_enabled: bool = False

    def enable_debug(self):
        self._debug_enabled = True

    @staticmethod
    def _print_message(message, file=sys.stdout):
        if message:
            if isinstance(message, list):
                message = "\n".join(message)

            file.write(f"{message}\n")

    def info(self, message: Union[str, List[str]]):
        self._print_message(message)

    def debug(self, message: Union[str, List[str]]):
        if self._debug_enabled:
            self._print_message(f"[DEBUG] {message}")

    def error(self, message: Union[str, List[str]]):
        self._print_message(message, file=sys.stderr)


_logger: Logger


def _subprocess_run(cmd: str, **kwargs) -> subprocess.CompletedProcess:
    _logger.debug(f"running: {cmd}")
    # We use 'shell=True', because want to support configurations,
    # where client will want to provide environment variable to some arguments.
    # For example, in case if we will have the following docker run options:
    # "-u $(id -u):$(id -g)", we want substitution of env variables to happen
    # automatically.
    return subprocess.run(cmd, shell=True, **kwargs)


def _option_to_value(options: List[str]) -> Dict[str, Any]:
    """
    Very simplified version of parser for command (docker) options.
    It implies that every option has a single value.
    Cases when it is a flag without value,
    or option, which has multiple values are not supported.
    It should be enough for our usecases.

    Args:
        options: list with options, like ["-f", "Dockerfile", "--tag", "not-important"]

    Returns:
        Dict, where keys are option names, and values are option values,
        e.g. {"-f": "Dockerfile", "--tag": "not-important"}
    """
    result: Dict[str, Any] = {}
    for idx, option in enumerate(options):
        if option.startswith("-"):
            if idx + 1 < len(options) and not options[idx + 1].startswith("-"):
                result[option] = options[idx + 1]
            else:
                result[option] = None
    return result


def _get_value_from_options(all_options: Dict[str, Any], target_names: Set[str]) -> Optional[str]:
    """
    The same option can be addressed by different names (e.g. "-f" and "--file").
    When we need to get value by option name, we should provide list of target names.
    If at least one of the target names is present in the options, it is OK for us.
    """
    for o, value in all_options.items():
        if o in target_names:
            return value
    return None


def set_user_if_not_set_yet(docker_run_options: List[str]) -> List[str]:
    """
    By default, we want to run actual instructions inside container as
    those user, which runs rego command on host. It is desired behavior
    for most part of the cases, but it can be overridden by config.
    """
    user_already_set = {"-u", "--user"} & set(docker_run_options)
    if not user_already_set:
        docker_run_options.extend(["--user", "$(id -u):$(id -g)"])
    return docker_run_options


def drop_interactive_if_not_tty(docker_run_options: List[str]) -> List[str]:
    """
    It is common thing to use "-it" flags when running docker containers
    to debug something there (pytest with --pdb option). It should be very
    common to have "test" commands to be configured with "-it", but it
    may lead to problems on CI runners, as they don't have TTY, see
    for example: https://github.com/actions/runner/issues/808
    We want to let users have "-it" flags and auto-detect situations,
    where command is run on setup without TTY, in this case we will drop
    -i/--interactive flag for run options.
    """
    if sys.stdin.isatty():
        return docker_run_options

    for f in ("--interactive", "-i"):
        if f in docker_run_options:
            _str = " ".join(docker_run_options)
            _logger.debug(f"the input device is not TTY, dropping '{f}' from '{_str}'")
            docker_run_options.remove(f)

    for idx, value in enumerate(docker_run_options):
        if value.startswith("-") and not value.startswith("--") and "i" in value:
            _logger.debug(f"the input device is not TTY, dropping 'i' from '{value}'")
            docker_run_options[idx] = value.replace("i", "")

    return docker_run_options


class Image:
    def __init__(self, container_cfg: dict):
        self._cfg = container_cfg
        self._img_tag: str = ""

    def prepare(self):
        image_name = self._cfg.get("docker_image")
        if image_name:
            self._img_tag = image_name
        else:
            self._img_tag = self._build_image()

    def _build_image(self) -> str:
        options_from_config = _string_as_list(self._cfg.get("docker_build_options"))
        option_to_value = _option_to_value(options_from_config)

        generated_options = ["."]  # build in the current directory
        if not _get_value_from_options(option_to_value, {"-f", "--file"}):
            generated_options.extend(["--file", self._cfg["docker_file_path"]])

        tag = _get_value_from_options(option_to_value, {"-t", "--tag"})
        if not tag:
            tag = f"{self._cfg['name']}-for-{REPO_NAME}"
            generated_options.extend(["--tag", tag])

        run = ["docker", "build"] + generated_options + options_from_config
        _subprocess_run(" ".join(run), stdout=subprocess.DEVNULL)
        return tag

    def run(self, docker_run_options: List[str], command_to_run: str):
        full_docker_command = (
            ["docker", "run", "--quiet", "-e", f"REGO_CONTAINER_NAME={self._cfg['name']}"]
            + docker_run_options
            + [self._img_tag]
            + [command_to_run]
        )
        return _subprocess_run(" ".join(full_docker_command))

    def cleanup(self):
        pass


class Composition:
    compose_base = "docker compose"

    def __init__(self, container_cfg: dict):
        self._cfg = container_cfg
        self._compose_file: str = ""
        self._generated_options: List[str] = []
        self._compose_options_from_config: List[str] = _string_as_list(
            self._cfg.get("docker_compose_options")
        )

    def prepare(self):
        option_to_value = _option_to_value(self._compose_options_from_config)

        progress_option = _get_value_from_options(option_to_value, {"--progress"})
        if not progress_option:
            # We do want to be quite by default.
            self._generated_options.extend(["--progress", "quiet"])

        # We must support overriding of file name, at least because docker compose
        # has multiple files support and users may want to use something like:
        # docker compose -f docker-compose.yml -f docker-compose.override.yml run ...
        self._compose_file = _get_value_from_options(option_to_value, {"-f", "--file"}) or ""
        if not self._compose_file:
            self._compose_file = self._cfg["docker_compose_file_path"]
            self._generated_options.extend(["--file", self._compose_file])

    def run(
        self, docker_run_options: List[str], command_to_run: str
    ) -> subprocess.CompletedProcess:
        docker_compose_run_cmd = (
            [self.compose_base]
            + self._generated_options
            + self._compose_options_from_config
            + ["run"]
            + docker_run_options
            + [self._cfg["docker_compose_service"]]
            + [command_to_run]
        )
        return _subprocess_run(" ".join(docker_compose_run_cmd))

    def cleanup(self):
        # Clean up after ourselves. It should be completely silent,
        # this is the reason why we redirect stdout and stderr to /dev/null
        _subprocess_run(
            f"{self.compose_base} down --remove-orphans",
            stdout=subprocess.DEVNULL,
        )
        _subprocess_run(
            f"{self.compose_base} --file {self._compose_file} rm -fsv",
            stdout=subprocess.DEVNULL,
        )


class Container:
    def __init__(self, container_cfg: dict):
        self._docker_backend: Union[Composition, Image] = (
            Composition(container_cfg)
            if "docker_compose_service" in container_cfg
            else Image(container_cfg)
        )

    def __enter__(self):
        self._docker_backend.prepare()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self._docker_backend.cleanup()

    def run_command(
        self, docker_run_options: List[str], command_to_run: str
    ) -> subprocess.CompletedProcess:
        docker_run_options = set_user_if_not_set_yet(docker_run_options)
        docker_run_options = drop_interactive_if_not_tty(docker_run_options)
        return self._docker_backend.run(docker_run_options, command_to_run)


def _string_as_list(shell_cmd: Optional[str]) -> List[str]:
    if not shell_cmd:
        return []
    return shell_cmd.split()


def _determine_config_path(path_from_user: Optional[str], for_write: bool = False):
    if path_from_user:
        if for_write:
            # When user asks to write config (--init) under some non-default path,
            # we are not going to check much.
            return Path(path_from_user)
        else:
            if not os.path.isfile(path_from_user):
                _logger.error(
                    f"file, which you tried to use as config, doesn't exist: '{path_from_user}'"
                )
                sys.exit(os.EX_UNAVAILABLE)
            return Path(path_from_user)
    return Path(DEFAULT_CFG_PATH)


def _read_config(config_path: Path) -> dict:
    config: dict
    if os.path.isfile(config_path):
        with open(config_path, "rb") as f:
            config = tomllib.load(f)
            _logger.debug(f"config loaded from {config_path.absolute()}")
    else:
        _logger.info(
            f"Config is not created yet.\nPlease initialize it with '{TOOL_RELATIVE_PATH} --init'"
        )
        sys.exit(os.EX_OK)

    return config


class TomlParser:
    """
    It is a very-very simplified parser of toml files, which we will
    use to parse rego config, if tomllib/tomli is not available on target system.
    This parser was tested only for basic rego config files and not supposed to
    be used for something else. Even for rego-specific configs it might have
    some restrictions (multiline lists, or something else might be not supported).
    Hope this parser will not get into the game too often.
    """

    import json

    def load(self, file):
        result: dict = {}

        current_section: dict = {}
        current_section_name = None
        current_section_type: Optional[type] = None

        def _dump_current_section_to_result():
            if not current_section_name:
                return None

            if current_section_type is dict:
                result[current_section_name] = current_section
            elif current_section_type is list:
                if current_section_name not in result:
                    result[current_section_name] = []
                result[current_section_name].append(current_section)

        for line in file:
            line = line.decode().strip()

            # Skip empty lines or comments
            if not line or line.startswith("#"):
                continue

            if line.startswith("[[") and line.endswith("]]"):
                _dump_current_section_to_result()

                current_section_name = line[2:-2]
                current_section_type = list
                current_section = {}
                continue

            if line.startswith("[") and line.endswith("]"):
                _dump_current_section_to_result()

                current_section_name = line[1:-1]
                current_section_type = dict
                current_section = {}
                continue

            if "=" not in line:
                continue

            k, v = line.split("=", maxsplit=1)
            name = k.strip()
            value = v.strip()
            # Toml dumper (used to generate test configs) adds comma
            # after last element of the list, but this is invalid json.
            # Since this parser is very-very simple, we just will try
            # to drop that comma.
            value = self.json.loads(value.replace(",]", "]"))

            if not current_section_name:
                # This is for root-level settings (not sections)
                result[name] = value
                continue

            current_section[name] = value

        _dump_current_section_to_result()
        return result


def _init_config_and_exit(config_path: Path):
    if os.path.isfile(config_path):
        _logger.error(
            f"file '{config_path}' already exist.\n"
            "Please review that file. If it is needed, you can either:\n"
            "- keep it on the same place, and generate new config "
            "under different path/name (use '--config')\n"
            "- move it to other place and try to call '--init' again\n"
            "If you don't need that file, just remove it and try again."
        )
        sys.exit(os.EX_PROTOCOL)

    with open(config_path, "w") as fn:
        fn.write(INITIAL_CONFIG_CONTENT)

    _logger.info(f"config created: {config_path}")
    sys.exit(os.EX_OK)


def _get_command_config(command_name: str, cfg: dict) -> dict:
    validated, errors = _validate_commands(cfg.get("commands", []))
    commands_with_matching_names = [c for c in validated if c["name"] == command_name]

    if not commands_with_matching_names:
        rc = os.EX_UNAVAILABLE
        _logger.info([f"command '{command_name}' is not present in the config"])
        if errors:
            _logger.error(
                [
                    "errors detected in 'commands' configurations "
                    "(probably this is the reason why command can't be found):",
                ]
                + [f"  - {e}" for e in errors]
            )
            rc = os.EX_CONFIG
        sys.exit(rc)

    return commands_with_matching_names[0]


def _get_container_config(target_container_name: str, cfg: dict) -> dict:
    containers_with_target_name = [
        c for c in cfg.get("docker_containers", []) if c.get("name") == target_container_name
    ]
    valid_containers, errors = _validate_containers(containers_with_target_name)

    if not valid_containers:
        if errors:
            output = [f"Container '{target_container_name}' is invalid:"]
            for e in errors:
                output.append(f"  - {e}")
        else:
            output = [f"Container '{target_container_name}' is not found in the config."]
        output.append(
            "Please use '--containers' option to list all containers, present in the config"
        )
        _logger.error(output)
        sys.exit(os.EX_CONFIG)

    return valid_containers[0]


def _generate_bin_sh_cmd(commands: List[str]):
    return f"/bin/sh -c '{' && '.join(commands)}'"


def _generate_command_to_run(command_cfg: dict, command_options: List[str]) -> str:
    before = command_cfg.get("before", [])

    execute = " ".join([command_cfg["execute"]] + command_options)

    return _generate_bin_sh_cmd(before + [execute])


def _containers_to_use(
    cfg: dict, command_cfg: dict, containers_requested_via_cli: Optional[List[str]]
) -> list:
    """
    Command may be executed in one or several containers.
    Exact container(s) might be specified either in command config
    and/or overridden by cli parameters (--container/-c).
    Overrides from cli have higher priority.
    Also, via CLI user can ask to run command in ALL configured containers (-c "*")

    This function returns resulting list of containers, which should be used
    to handle the given command run.
    """
    containers_from_command_config = (
        [command_cfg["docker_container"]] if "docker_container" in command_cfg else []
    )
    containers_to_use = containers_requested_via_cli or containers_from_command_config

    if len(containers_to_use) == 1 and containers_to_use[0] == "*":
        valid_containers, _ = _validate_containers(cfg.get("docker_containers", []))
        containers_to_use = [c["name"] for c in valid_containers]

    return containers_to_use


def _generate_cleanup_cmd(command_cfg: dict) -> Optional[str]:
    after = command_cfg.get("after")
    if after:
        return _generate_bin_sh_cmd(after)
    return None


def _run_command(
    command_name: str,
    command_options: List[str],
    cfg: dict,
    containers_requested_via_cli: Optional[List[str]],
) -> int:
    command_cfg = _get_command_config(command_name, cfg)
    command_to_run = _generate_command_to_run(command_cfg, command_options)
    cleanup = _generate_cleanup_cmd(command_cfg)

    containers_to_use = _containers_to_use(cfg, command_cfg, containers_requested_via_cli)
    if not containers_to_use:
        res = _subprocess_run(command_to_run).returncode
        if cleanup:
            _subprocess_run(cleanup)
        return res

    results = {}
    for container_name in containers_to_use:
        with Container(_get_container_config(container_name, cfg)) as container:
            results[container_name] = container.run_command(
                docker_run_options=_string_as_list(command_cfg.get("docker_run_options")),
                command_to_run=command_to_run,
            ).returncode
        if cleanup:
            _subprocess_run(cleanup)

    if len(results) == 1:
        return list(results.values())[0]

    if all(r == 0 for r in results.values()):
        return 0

    nok_containers = {name: rc for name, rc in results.items() if rc != 0}
    _logger.error(f"command has returned not 0 for following containers: {nok_containers}")
    return -1


##################################################################################
# START OF "Validation rules"
##################################################################################
# class ValidationRules(TypedDict, total=False):
#     value_type: Union[type, tuple]
#     required: bool
#     check_with: Callable
#     # If this field is present, then some other fields are also required
#     requires_fields: Set[str]
#     # If this field is present, then some other fields should not be
#     # present in data
#     excludes_fields: Set[str]


class Validator:
    """
    We can't use well-known Pydantic, Cerberus or similar
    data validators, as they are not available in default
    Python installation, but we need to validate config file
    and provide some sane feedback to user in case of problems.
    This class implements simple validation logic, which we
    might need to validate our configuration.
    """

    _FIELD_FOR_GLOBAL_LEVEL_ERROR = "*"

    def __init__(
        self,
        schema: Dict[str, dict],
        one_of_optional_fields_required: Optional[Set[str]] = None,
    ):
        self._schema = schema
        self._one_of_optional_fields_required = one_of_optional_fields_required

    def validate(self, data: Mapping) -> dict:
        if not isinstance(data, dict):
            return {
                self._FIELD_FOR_GLOBAL_LEVEL_ERROR: [
                    f"must be represented by 'dict', got '{type(data).__name__}'"
                ]
            }

        errors: defaultdict = defaultdict(list)
        mandatory_fields = {f for f, rules in self._schema.items() if rules["required"] is True}
        for missing_mandatory_field in mandatory_fields - set(data.keys()):
            errors[missing_mandatory_field] = ["mandatory field missing"]

        for field, value in data.items():
            if field not in self._schema:
                errors[field] = ["unsupported field"]
                continue

            if not isinstance(value, self._schema[field]["value_type"]):
                expected_type = self._schema[field]["value_type"]

                err_details = "IF YOU SEE IT PLEASE REPORT BUG"
                if isinstance(expected_type, type):
                    err_details = expected_type.__name__
                elif isinstance(expected_type, tuple):
                    err_details = " | ".join([t.__name__ for t in expected_type])

                errors[field] = [f"should be of type {err_details}, got {type(value).__name__}"]
                continue

            field_errors = []
            if self._schema[field].get("check_with"):
                checker = self._schema[field]["check_with"]
                _error_from_checker = checker(value)
                if _error_from_checker:
                    field_errors.append(_error_from_checker)

            missing_required = {
                _field
                for _field in self._schema[field].get("requires_fields", set())
                if _field not in data
            }
            if missing_required:
                field_errors.append(
                    f"requires following fields to be present as well, "
                    f"but they are not found: {missing_required}"
                )

            present_conflicting = {
                _field
                for _field in self._schema[field].get("excludes_fields", set())
                if _field in data
            }
            if present_conflicting:
                field_errors.append(f"conflicting fields found: {present_conflicting}")

            if field_errors:
                errors[field].extend(field_errors)

        if self._one_of_optional_fields_required:
            if not self._one_of_optional_fields_required.intersection(set(data.keys())):
                errors[self._FIELD_FOR_GLOBAL_LEVEL_ERROR].append(
                    "one of the following fields "
                    f"must be present: {sorted(self._one_of_optional_fields_required)}"
                )

        if errors:
            return dict(errors)

        return {}


def _validate_name(name: str):
    _name = name
    _name = _name.replace("-", "")
    _name = _name.replace("_", "")
    if not _name.isalnum():
        return f"should consist only of letters, digits, '-', or '_', got '{name}'"
    return None


_command_validator = Validator(
    schema={
        "name": dict(value_type=str, required=True, check_with=_validate_name),
        "description": dict(value_type=str, required=True),
        "before": dict(value_type=list, required=False),
        "execute": dict(value_type=str, required=True),
        "after": dict(value_type=list, required=False),
        "examples": dict(value_type=list, required=False),
        # Docker section
        "docker_container": dict(
            value_type=str,
            required=False,
        ),
        "docker_run_options": dict(
            value_type=str,
            required=False,
            requires_fields={"docker_container"},
        ),
    }
)

_container_validator = Validator(
    schema={
        "name": dict(value_type=str, required=True, check_with=_validate_name),
        # Docker alternatives: image from repo
        "docker_image": dict(
            value_type=str,
            required=False,
            excludes_fields={"docker_file_path", "docker_compose_file_path"},
        ),
        # Docker alternatives: local Docker file to build
        "docker_file_path": dict(
            value_type=str,
            required=False,
            excludes_fields={"docker_image", "docker_compose_file_path"},
        ),
        "docker_build_options": dict(value_type=str, required=False),
        # Docker-compose alternative
        "docker_compose_file_path": dict(
            value_type=str,
            required=False,
            excludes_fields={"docker_file_path", "docker_image"},
            requires_fields={"docker_compose_service"},
        ),
        "docker_compose_options": dict(
            value_type=str, required=False, requires_fields={"docker_compose_service"}
        ),
        "docker_compose_service": dict(
            value_type=str,
            required=False,
            excludes_fields={"docker_file_path", "docker_image"},
            requires_fields={"docker_compose_file_path"},
        ),
    },
    one_of_optional_fields_required={
        "docker_file_path",
        "docker_image",
        "docker_compose_file_path",
        "docker_compose_options",
    },
)


def _validate_commands(
    commands: List[dict],
) -> Tuple[List[dict], List[str]]:
    errors = []
    valid_commands = []

    if not isinstance(commands, list):
        errors.append(f"commands should be represented by list, got {type(commands).__name__}")
        return valid_commands, errors

    for idx, cmd in enumerate(commands):
        cmd_errors = _command_validator.validate(cmd)
        if cmd_errors:
            for field, field_errors in cmd_errors.items():
                errors.append(f"commands.{idx}.{field}: {field_errors}")
        else:
            valid_commands.append(cmd)

    return valid_commands, sorted(errors)


def _validate_containers(
    containers: List[dict],
) -> Tuple[List[dict], List[str]]:
    errors = []
    valid_containers = []

    if not isinstance(containers, list):
        errors.append(
            f"docker_containers should be represented by list, got {type(containers).__name__}"
        )
        return valid_containers, errors

    for idx, container in enumerate(containers):
        container_errors = _container_validator.validate(container)
        if container_errors:
            for field, field_errors in container_errors.items():
                errors.append(f"docker_containers.{idx}.{field}: {field_errors}")
        else:
            valid_containers.append(container)

    return valid_containers, sorted(errors)


##################################################################################
# END OF "Validation rules"
##################################################################################


def _examples_representation(cmd: dict) -> List[str]:
    examples = cmd.get("examples")
    if not examples:
        return [f"{TOOL_RELATIVE_PATH} {cmd['name']}"]
    return [f"{TOOL_RELATIVE_PATH} {example}" for example in examples]


def _show_main_menu_and_exit(cfg: dict):
    validated, errors = _validate_commands(cfg.get("commands", []))

    commands = [
        f"  * {command['name']} - {command['description']} {_examples_representation(command)}"
        for command in validated
    ]

    if commands:
        _logger.info(["Following commands are available:"] + commands)
    else:
        _logger.info(
            ["Config file is present, but there are no any valid commands configured there"]
        )

    if errors:
        _logger.error(
            ["errors detected in configured commands:"] + [f"  - {err}" for err in errors]
        )

    if not commands and errors:
        sys.exit(os.EX_CONFIG)

    sys.exit(os.EX_OK)


def _show_configured_containers_and_exit(cfg: dict):
    validated, errors = _validate_containers(cfg.get("docker_containers", []))

    containers = [f"  * {data['name']}" for data in validated]
    if containers:
        _logger.info(["Following containers are available:"] + containers)
    else:
        _logger.info(["No any valid container configuration found"])

    if errors:
        _logger.error(
            ["errors detected in configured containers:"] + [f"  - {err}" for err in errors]
        )

    if not containers and errors:
        sys.exit(os.EX_CONFIG)

    sys.exit(os.EX_OK)


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(
        "-c",
        "--container",
        action="append",
        help='force command to be run in specific container(s). Use "*" to run in all containers',
    )
    parser.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="verbose output",
    )
    parser.add_argument(
        "--config",
        help="path to the actual config file",
    )
    parser.add_argument(
        "--containers",
        action="store_true",
        help="show all containers, present in the config file",
    )
    parser.add_argument(
        "--init",
        action="store_true",
        help="create and initialize config file",
    )
    parser.add_argument("-h", "--help", action="help")
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help=f"exact command to be executed (might be supplemented with options). "
        f"You could try `{TOOL_RELATIVE_PATH}` to get list of available commands.",
    )
    return parser.parse_args()


def main():
    global _logger
    _logger = Logger()

    try:
        args = _parse_arguments()
        if args.debug:
            _logger.enable_debug()
            _logger.debug("debug logging enabled")

        config_path = _determine_config_path(args.config, for_write=True if args.init else False)
        if args.init:
            _init_config_and_exit(config_path)

        cfg: dict = _read_config(config_path)
        if args.containers:
            _show_configured_containers_and_exit(cfg)

        if not args.command:
            _show_main_menu_and_exit(cfg)

        cmd_name = args.command[0]
        cmd_options = args.command[1:]

        rc = _run_command(cmd_name, cmd_options, cfg, containers_requested_via_cli=args.container)

    except Exception as ex:
        _logger.error(f"error happen: {ex}")
        if args.debug:
            raise ex
        rc = os.EX_SOFTWARE

    sys.exit(rc)


if __name__ == "__main__":
    main()
