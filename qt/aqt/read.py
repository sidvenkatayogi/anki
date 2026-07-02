# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

"""Read tab (MCAT fork).

A thin Qt window hosting the SvelteKit `read` page, which fetches a short
passage + quiz from the configured mcat-tools sync server. See
specs/PRD1.md.

Note: window title is a plain hardcoded string (not tr.*()) — see the i18n
decision recorded in the frontend plan for this run; ftl/core strings should
be added properly in a later pass.
"""

from __future__ import annotations

from collections.abc import Callable

import aqt
import aqt.main
from aqt.qt import *
from aqt.utils import disable_help_button, restoreGeom, saveGeom
from aqt.webview import AnkiWebView, AnkiWebViewKind


class ReadStats(QDialog):
    def __init__(self, mw: aqt.main.AnkiQt) -> None:
        QDialog.__init__(self, mw, Qt.WindowType.Window)
        self.mw = mw
        self.name = "readStats"
        mw.garbage_collect_on_dialog_finish(self)
        self.setMinimumSize(600, 400)
        disable_help_button(self)
        restoreGeom(self, self.name, default_size=(800, 800))

        self.web = AnkiWebView(kind=AnkiWebViewKind.READ_STATS)
        self.web.load_sveltekit_page("read")
        layout = QVBoxLayout()
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.web)
        self.setLayout(layout)

        self.setWindowTitle("Read")
        self.show()

    def reject(self) -> None:
        self.web.cleanup()
        self.web = None  # type: ignore
        saveGeom(self, self.name)
        aqt.dialogs.markClosed("ReadStats")
        QDialog.reject(self)

    def closeWithCallback(self, callback: Callable[[], None]) -> None:
        self.reject()
        callback()
