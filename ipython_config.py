c = get_config()  # noqa

c.InteractiveShellApp.exec_lines = [r"%autoreload 2"]

c.InteractiveShellApp.extensions = ["autoreload"]
