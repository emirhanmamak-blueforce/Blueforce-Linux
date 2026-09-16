"""bfos — Blueforce Field OS operator console.

Python operator console for the Blueforce field fleet, in Turkish, with a
simple default view (``1) Kur``, ``2) Durum``, ``3) Çıkış``) and a detailed view
(``--full``) that exposes the full operation catalogue.

The console is a thin front end: it drives the existing installer, the existing
Ansible playbooks and the existing ``bf-*`` diagnostics tools. It never invents
a playbook, never edits the inventory and never talks to a device itself.

No third-party dependency: standard library only (Python 3.8+).
"""

from .config import VERSION

__version__ = VERSION
__all__ = ["VERSION", "__version__"]
