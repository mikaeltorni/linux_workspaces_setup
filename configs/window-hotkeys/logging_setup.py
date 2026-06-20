"""logging_setup.py - centralized logging for the window-hotkeys helpers.

Provides a single factory, :func:`get_logger`, used by every window-hotkeys
Python module so that logs share one format, one set of levels, and one
destination. Every repository-generated log file is written under a ``.log/``
directory (created on demand) and is also mirrored to ``stderr`` so the systemd
journal still captures the running service's output.

Components:
  - VERBOSE: Custom log level below DEBUG for high-frequency event traces.
  - resolve_log_dir: Locate (and create) the repository ``.log/`` directory.
  - get_logger: Build a configured logger with file + stream handlers.

Usage:
  from logging_setup import get_logger
  log = get_logger("ctrl-back-window-tiler")
  log.info("service started")
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

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
    """Build (or fetch) a logger writing to ``.log/<name>.log`` and ``stderr``.

    The logger is configured exactly once per name; repeated calls return the
    same instance without duplicating handlers. The stream handler keeps the
    systemd journal populated, while the file handler satisfies the repository
    ``.log/`` storage requirement.

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

        log_dir = resolve_log_dir(base_dir)
        file_handler = logging.FileHandler(log_dir / f"{name}.log", encoding="utf-8")
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        logger.addHandler(stream_handler)

    return _add_verbose_method(logger)
