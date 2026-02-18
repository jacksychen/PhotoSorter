"""PhotoSorter GUI — PySide6 cluster viewer."""

from __future__ import annotations

import json
import sys
from collections import OrderedDict
from pathlib import Path

from PySide6.QtCore import (
    QRunnable,
    QSize,
    Qt,
    QThreadPool,
    Signal,
    Slot,
    QObject,
    QRect,
    QPoint,
)
from PIL import Image, ImageOps
from PySide6.QtGui import QAction, QFont, QIcon, QImage, QPainter, QPainterPath, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QFileDialog,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QScrollArea,
    QSplitter,
    QStatusBar,
    QToolBar,
    QVBoxLayout,
    QWidget,
    QLayout,
    QSizePolicy,
    QStyle,
    QMessageBox,
)


# ---------------------------------------------------------------------------
# FlowLayout — wraps children automatically based on available width
# ---------------------------------------------------------------------------

class FlowLayout(QLayout):
    def __init__(self, parent=None, margin=-1, h_spacing=8, v_spacing=8):
        super().__init__(parent)
        self._h_space = h_spacing
        self._v_space = v_spacing
        self._items: list = []
        if margin >= 0:
            self.setContentsMargins(margin, margin, margin, margin)

    def addItem(self, item):
        self._items.append(item)

    def count(self):
        return len(self._items)

    def itemAt(self, index):
        if 0 <= index < len(self._items):
            return self._items[index]
        return None

    def takeAt(self, index):
        if 0 <= index < len(self._items):
            return self._items.pop(index)
        return None

    def expandingDirections(self):
        return Qt.Orientation(0)

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        return self._do_layout(QRect(0, 0, width, 0), test_only=True)

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._do_layout(rect, test_only=False)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        size = QSize()
        for item in self._items:
            size = size.expandedTo(item.minimumSize())
        m = self.contentsMargins()
        size += QSize(m.left() + m.right(), m.top() + m.bottom())
        return size

    def _do_layout(self, rect, test_only):
        m = self.contentsMargins()
        effective = rect.adjusted(m.left(), m.top(), -m.right(), -m.bottom())
        x = effective.x()
        y = effective.y()
        line_height = 0

        for item in self._items:
            w = item.sizeHint().width()
            h = item.sizeHint().height()
            next_x = x + w + self._h_space
            if next_x - self._h_space > effective.right() and line_height > 0:
                x = effective.x()
                y = y + line_height + self._v_space
                next_x = x + w + self._h_space
                line_height = 0
            if not test_only:
                item.setGeometry(QRect(QPoint(x, y), item.sizeHint()))
            x = next_x
            line_height = max(line_height, h)

        return y + line_height - rect.y() + m.bottom()


# ---------------------------------------------------------------------------
# Async thumbnail loader
# ---------------------------------------------------------------------------

class _LoaderSignals(QObject):
    finished = Signal(str, QImage)  # (path, image)


class _ThumbnailLoader(QRunnable):
    THUMB_SIZE = 160

    def __init__(self, path: str):
        super().__init__()
        self.path = path
        self.signals = _LoaderSignals()

    def run(self):
        try:
            with Image.open(self.path) as pil_img:
                pil_img = ImageOps.exif_transpose(pil_img)
                pil_img = pil_img.convert("RGBA")
                data = pil_img.tobytes("raw", "RGBA")
                img = QImage(data, pil_img.width, pil_img.height, QImage.Format_RGBA8888).copy()
        except Exception:
            img = QImage()
        if not img.isNull():
            img = img.scaled(
                self.THUMB_SIZE,
                self.THUMB_SIZE,
                Qt.KeepAspectRatio,
                Qt.SmoothTransformation,
            )
        self.signals.finished.emit(self.path, img)


# ---------------------------------------------------------------------------
# Thumbnail card widget
# ---------------------------------------------------------------------------

def _round_pixmap(pm: QPixmap, radius: float = 8.0) -> QPixmap:
    """Return a copy of *pm* with rounded corners."""
    rounded = QPixmap(pm.size())
    rounded.fill(Qt.transparent)
    painter = QPainter(rounded)
    painter.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(0, 0, pm.width(), pm.height(), radius, radius)
    painter.setClipPath(path)
    painter.drawPixmap(0, 0, pm)
    painter.end()
    return rounded


class _PhotoCard(QWidget):
    THUMB_SIZE = 160

    def __init__(self, filename: str, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 2)
        layout.setSpacing(4)
        layout.setAlignment(Qt.AlignCenter)

        self.image_label = QLabel()
        self.image_label.setFixedSize(self.THUMB_SIZE, self.THUMB_SIZE)
        self.image_label.setAlignment(Qt.AlignCenter)
        self.image_label.setStyleSheet(
            "background: palette(midlight); border-radius: 8px;"
        )
        self.image_label.setText("Loading…")

        self.name_label = QLabel(filename)
        self.name_label.setAlignment(Qt.AlignCenter)
        self.name_label.setMaximumWidth(self.THUMB_SIZE)
        self.name_label.setWordWrap(True)
        font = self.name_label.font()
        font.setPointSize(11)
        self.name_label.setFont(font)
        self.name_label.setStyleSheet("color: palette(dark);")

        layout.addWidget(self.image_label)
        layout.addWidget(self.name_label)

    def set_pixmap(self, pm: QPixmap):
        if pm.isNull():
            self.image_label.setText("Not found")
        else:
            self.image_label.setPixmap(_round_pixmap(pm))
            self.image_label.setText("")
            self.image_label.setStyleSheet("border-radius: 8px;")

    def sizeHint(self):
        return QSize(self.THUMB_SIZE + 12, self.THUMB_SIZE + 36)


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("PhotoSorter Viewer")
        self.resize(1100, 700)
        self.setUnifiedTitleAndToolBarOnMac(True)

        self._manifest = {}
        self._clusters: list[dict] = []
        self._cache: OrderedDict[str, QPixmap] = OrderedDict()
        self._cache_limit = 500
        self._pending_loaders: list[_ThumbnailLoader] = []
        self._pool = QThreadPool.globalInstance()

        # --- toolbar (unified with title bar on macOS) ---
        toolbar = QToolBar("Main")
        toolbar.setMovable(False)
        toolbar.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.addToolBar(toolbar)

        open_icon = self.style().standardIcon(QStyle.SP_DirOpenIcon)
        open_action = toolbar.addAction(open_icon, "Open")
        open_action.setToolTip("Open manifest.json")
        open_action.triggered.connect(self._open_manifest)

        # --- splitter ---
        splitter = QSplitter(Qt.Horizontal)
        self.setCentralWidget(splitter)

        # left: cluster list (Finder-style source list)
        self._list = QListWidget()
        self._list.setMinimumWidth(180)
        self._list.setMaximumWidth(260)
        self._list.setFrameShape(QListWidget.Shape.NoFrame)
        self._list.setStyleSheet(
            "QListWidget {"
            "  background: palette(window);"
            "  border: none;"
            "  outline: none;"
            "}"
            "QListWidget::item {"
            "  padding: 6px 12px;"
            "  border-radius: 6px;"
            "  margin: 1px 6px;"
            "}"
            "QListWidget::item:selected {"
            "  background: palette(highlight);"
            "  color: palette(highlighted-text);"
            "}"
            "QListWidget::item:hover:!selected {"
            "  background: palette(midlight);"
            "}"
        )
        self._list.currentRowChanged.connect(self._on_cluster_selected)
        splitter.addWidget(self._list)

        # right: scroll area with flow layout
        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        splitter.addWidget(self._scroll)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)

        self._grid_container = QWidget()
        self._grid_layout = FlowLayout(self._grid_container, margin=16)
        self._grid_container.setLayout(self._grid_layout)
        self._scroll.setWidget(self._grid_container)

        # --- status bar ---
        self._status = QStatusBar()
        self._status.setStyleSheet(
            "QStatusBar { color: palette(dark); font-size: 12px; }"
        )
        self.setStatusBar(self._status)

    # ----- manifest loading -----

    def _open_manifest(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Select manifest.json", "", "JSON Files (*.json)"
        )
        if not path:
            return
        self._load_manifest(path)

    def _load_manifest(self, path: str):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            QMessageBox.critical(self, "Error", f"Failed to load manifest:\n{exc}")
            return

        if data.get("version") != 1:
            QMessageBox.warning(
                self, "Warning", f"Unsupported manifest version: {data.get('version')}"
            )

        self._manifest = data
        self._clusters = data.get("clusters", [])
        self._cache.clear()
        self._populate_sidebar()

        total = data.get("total", 0)
        n_clusters = len(self._clusters)
        status = f"{total} photos · {n_clusters} clusters"
        self._status.showMessage(status)
        self.setWindowTitle(f"PhotoSorter Viewer — {Path(path).name}")

    def _populate_sidebar(self):
        self._list.blockSignals(True)
        self._list.clear()
        total = self._manifest.get("total", 0)
        item_all = QListWidgetItem(f"All Photos ({total})")
        item_all.setData(Qt.UserRole, -1)
        self._list.addItem(item_all)
        for cluster in self._clusters:
            cid = cluster["cluster_id"]
            count = cluster["count"]
            item = QListWidgetItem(f"Cluster {cid} ({count} photos)")
            item.setData(Qt.UserRole, cid)
            self._list.addItem(item)
        self._list.blockSignals(False)
        self._list.setCurrentRow(0)

    # ----- grid rendering -----

    @Slot(int)
    def _on_cluster_selected(self, row: int):
        if row < 0:
            return
        item = self._list.item(row)
        cid = item.data(Qt.UserRole)
        if cid == -1:
            photos = [p for c in self._clusters for p in c["photos"]]
        else:
            photos = next(
                (c["photos"] for c in self._clusters if c["cluster_id"] == cid), []
            )
        self._show_photos(photos)

    def _show_photos(self, photos: list[dict]):
        # clear existing cards
        while self._grid_layout.count():
            child = self._grid_layout.takeAt(0)
            if child.widget():
                child.widget().deleteLater()
        self._pending_loaders.clear()

        for photo in photos:
            path = photo["original_path"]
            filename = photo["filename"]
            card = _PhotoCard(filename, self._grid_container)
            self._grid_layout.addWidget(card)

            if path in self._cache:
                card.set_pixmap(self._cache[path])
            else:
                loader = _ThumbnailLoader(path)
                loader.signals.finished.connect(
                    lambda p, pm, c=card, ld=loader: self._on_thumb_loaded(p, pm, c, ld)
                )
                self._pending_loaders.append(loader)
                self._pool.start(loader)

    @Slot(str, QImage)
    def _on_thumb_loaded(
        self, path: str, img: QImage, card: _PhotoCard, loader: _ThumbnailLoader
    ):
        pm = QPixmap.fromImage(img)
        self._cache[path] = pm
        self._cache.move_to_end(path)
        while len(self._cache) > self._cache_limit:
            self._cache.popitem(last=False)
        card.set_pixmap(pm)
        if loader in self._pending_loaders:
            self._pending_loaders.remove(loader)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window._open_manifest()
    if not window._manifest:
        sys.exit(0)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
