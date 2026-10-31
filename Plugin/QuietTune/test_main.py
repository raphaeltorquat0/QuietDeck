import main

assert main.desired(running=False, force=False) == "Vidro"
assert main.desired(running=True, force=False) == "Opaco"
assert main.desired(running=True, force=True) == "Vidro"
print("ok")
