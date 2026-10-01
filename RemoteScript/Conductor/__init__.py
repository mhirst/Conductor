import importlib

from . import Conductor as _module


class _Host(object):
    """Thin wrapper Live talks to. It lets the script hot-reload its own code
    (cmd "dev_reload") without restarting Live: the old instance is torn down and a
    fresh one is built from the re-imported module."""

    def __init__(self, c_instance):
        self._c = c_instance
        self._impl = _module.Conductor(c_instance)

    def update_display(self):
        self._impl.update_display()
        if getattr(self._impl, 'reload_requested', False):
            self._reload()

    def _reload(self):
        global _module
        self._impl.disconnect()
        try:
            _module = importlib.reload(_module)
            self._c.show_message('Conductor: reloaded')
        except Exception as e:
            self._c.log_message('[Conductor] reload failed: %s' % e)
        self._impl = _module.Conductor(self._c)

    def __getattr__(self, name):
        return getattr(self._impl, name)


def create_instance(c_instance):
    return _Host(c_instance)
