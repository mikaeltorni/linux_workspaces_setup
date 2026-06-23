"""logging_setup.py - centralized logging for the window-hotkeys helpers.

Provides the single logging module used by every window-hotkeys Python module.
It exposes :func:`get_logger` for idempotent logger setup and :func:`log_call`
for standard call tracing. Service runs write to ``stderr`` for journald;
helper/CLI runs also write under the repository ``.log/`` directory.

Components:
  - VERBOSE: Custom log level below DEBUG for high-frequency event traces.
  - resolve_log_dir: Locate (and create) the repository ``.log/`` directory.
  - get_logger: Build a configured logger with file + stream handlers.
  - log_call: Decorator that records bound arguments on entry and return values
    on exit, with file:function context in every record.

Usage:
  from logging_setup import get_logger, log_call
  log = get_logger("ctrl-back-window-tiler")
  log.info("service started")
"""

from __future__ import annotations

import functools
import inspect
import logging
import os
from pathlib import Path
from typing import Any, Callable, TypeVar


F = TypeVar("F", bound=Callable[..., Any])

# Custom level between NOTSET and DEBUG for very frequent traces (per the
# guideline's verbose/debug/info/warn/error level set). Registered once so
# logger.verbose(...) reads naturally at call sites.
VERBOSE = 5
logging.addLevelName(VERBOSE, "VERBOSE")

_LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"


def resolve_log_dir(base_dir: str | os.PathLike[str] | None = None) -> Path:
    """Return the ``.log/`` directory to write to, creating it if needed.

    Args:
        base_dir: Directory that should contain ``.log/``. When omitted, the
            ``WINDOW_HOTKEYS_LOG_DIR`` environment variable is honored first,
            then the directory holding this module (the repository checkout or
            the deployed ``~/.local/bin`` directory).

    Returns:
        The created ``.log/`` :class:`~pathlib.Path`.
    """
    if base_dir is None:
        env_dir = os.environ.get("WINDOW_HOTKEYS_LOG_DIR")
        base = Path(env_dir) if env_dir else Path(__file__).resolve().parent
    else:
        base = Path(base_dir)

    log_dir = base / ".log"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


def _should_write_log_file(base_dir: str | os.PathLike[str] | None) -> bool:
    """Return whether this process should mirror records to ``.log/``.

    Args:
        base_dir: Explicit base directory requested by the caller or a test.

    Returns:
        True for helper/CLI runs and explicit test directories; False for
        systemd service runs where journald already captures stderr.
    """
    if base_dir is not None:
        return True
    if os.environ.get("WINDOW_HOTKEYS_LOG_TO_FILE") == "1":
        return True
    if os.environ.get("INVOCATION_ID") or os.environ.get("JOURNAL_STREAM"):
        return False
    return True


def _add_verbose_method(logger: logging.Logger) -> logging.Logger:
    """Attach a ``verbose`` convenience method to ``logger`` if absent.

    Args:
        logger: Logger to augment with a VERBOSE-level helper.

    Returns:
        The same logger, now exposing ``logger.verbose(msg, *args)``.
    """
    if not hasattr(logger, "verbose"):
        def verbose(message: str, *args: object, **kwargs: object) -> None:
            if logger.isEnabledFor(VERBOSE):
                logger.log(VERBOSE, message, *args, **kwargs)

        logger.verbose = verbose  # type: ignore[attr-defined]
    return logger


def get_logger(
    name: str,
    *,
    level: int = logging.INFO,
    base_dir: str | os.PathLike[str] | None = None,
) -> logging.Logger:
    """Build or fetch a centralized window-hotkeys logger.

    The logger is configured exactly once per name; repeated calls return the
    same instance without duplicating handlers. Service runs log to ``stderr``
    for journald; helper and CLI runs also mirror to ``.log/<name>.log``.
    Logging setup is best-effort and falls back to a null handler if no sink can
    be created.

    Args:
        name: Logger name; also the log file stem (``.log/<name>.log``).
        level: Lowest level to emit. Defaults to ``logging.INFO``.
        base_dir: Optional base directory for ``.log/``; see
            :func:`resolve_log_dir`. Overridable so tests can use a temp dir.

    Returns:
        A configured :class:`logging.Logger` exposing ``verbose``, ``debug``,
        ``info``, ``warning``, and ``error`` methods.
    """
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.propagate = False

    if not logger.handlers:
        formatter = logging.Formatter(_LOG_FORMAT, datefmt=_DATE_FORMAT)
        added_handler = False

        if _should_write_log_file(base_dir):
            try:
                log_dir = resolve_log_dir(base_dir)
                file_handler = logging.FileHandler(
                    log_dir / f"{name}.log",
                    encoding="utf-8",
                )
                file_handler.setFormatter(formatter)
                logger.addHandler(file_handler)
                added_handler = True
            except OSError:
                added_handler = False

        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        logger.addHandler(stream_handler)
        added_handler = True

        if not added_handler:
            logger.addHandler(logging.NullHandler())

    return _add_verbose_method(logger)


def log_call(logger: logging.Logger, level: int = logging.DEBUG) -> Callable[[F], F]:
    """Trace a function by logging arguments on entry and return value on exit.

    Each record carries the wrapped function's ``file:qualname`` so call traces
    are searchable without repeating that context at every call site.

    Args:
        logger: Centralized logger returned by :func:`get_logger`.
        level: Logging level used for the enter and exit records.

    Returns:
        Decorator that wraps the target callable.
    """

    def decorator(func: F) -> F:
        location = f"{Path(func.__code__.co_filename).name}:{func.__qualname__}"
        signature = inspect.signature(func)

        @functools.wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            rendered = ", ".join(
                f"{name}={value!r}" for name, value in bound.arguments.items()
            )
            logger.log(level, "ENTER %s(%s)", location, rendered)
            result = func(*args, **kwargs)
            logger.log(level, "EXIT %s -> %r", location, result)
            return result

        return wrapper  # type: ignore[return-value]

    return decorator
