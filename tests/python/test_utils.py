"""Tests for photosorter.utils."""

from pathlib import Path

from photosorter import utils as utils_mod
from photosorter.utils import discover_images, natural_sort_key


def test_natural_sort_key_orders_digit_groups():
    paths = [Path("IMG_10.jpg"), Path("IMG_2.jpg"), Path("IMG_1.jpg")]
    ordered = sorted(paths, key=natural_sort_key)
    assert [p.name for p in ordered] == ["IMG_1.jpg", "IMG_2.jpg", "IMG_10.jpg"]


def test_discover_images_filters_supported_extensions_and_sorts(tmp_path):
    # Supported files (mixed case extensions)
    (tmp_path / "IMG_10.JPG").write_text("x")
    (tmp_path / "IMG_2.jpg").write_text("x")
    (tmp_path / "IMG_1.CR2").write_text("x")
    # Unsupported and nested files should be ignored
    (tmp_path / "notes.txt").write_text("x")
    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / "IMG_0.jpg").write_text("x")

    images = discover_images(tmp_path)
    assert [p.name for p in images] == ["IMG_1.CR2", "IMG_2.jpg", "IMG_10.JPG"]
    assert all(p.parent == tmp_path for p in images)


def test_setup_logging_configures_and_returns_photosorter_logger(monkeypatch):
    called = {}

    def fake_basic_config(**kwargs):
        called.update(kwargs)

    monkeypatch.setattr(utils_mod.logging, "basicConfig", fake_basic_config)
    logger = utils_mod.setup_logging()

    assert logger.name == "photosorter"
    assert called["level"] == utils_mod.logging.INFO
    assert called["datefmt"] == "%H:%M:%S"
    assert "%(levelname)" in called["format"]


def test_ensure_logging_calls_setup_when_no_handlers(monkeypatch):
    class _FakeLogger:
        def __init__(self, handlers):
            self.handlers = list(handlers)

        def addHandler(self, handler):
            self.handlers.append(handler)

        def removeHandler(self, handler):
            if handler in self.handlers:
                self.handlers.remove(handler)

    photosorter_logger = _FakeLogger([])
    root_logger = _FakeLogger([])
    calls = {"n": 0}

    def fake_get_logger(name=None):
        return photosorter_logger if name == "photosorter" else root_logger

    monkeypatch.setattr(utils_mod.logging, "getLogger", fake_get_logger)
    monkeypatch.setattr(utils_mod, "setup_logging", lambda: calls.__setitem__("n", calls["n"] + 1))

    utils_mod.ensure_logging()
    assert calls["n"] == 1


def test_ensure_logging_is_noop_when_handlers_exist(monkeypatch):
    class _FakeLogger:
        def __init__(self, handlers):
            self.handlers = list(handlers)

        def addHandler(self, handler):
            self.handlers.append(handler)

        def removeHandler(self, handler):
            if handler in self.handlers:
                self.handlers.remove(handler)

    photosorter_logger = _FakeLogger([object()])
    root_logger = _FakeLogger([])
    calls = {"n": 0}

    def fake_get_logger(name=None):
        return photosorter_logger if name == "photosorter" else root_logger

    monkeypatch.setattr(utils_mod.logging, "getLogger", fake_get_logger)
    monkeypatch.setattr(utils_mod, "setup_logging", lambda: calls.__setitem__("n", calls["n"] + 1))

    utils_mod.ensure_logging()
    assert calls["n"] == 0
