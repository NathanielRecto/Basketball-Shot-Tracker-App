# Resources (local only)

`DetectorV2.mlpackage` and `DetectorV2.json` go here and are bundled into the app (see `xtool.yml`).
They are gitignored, like the detector's `.pt` weights in the research repo. To produce them:

```bash
cd ../Python_Raw && ~/coreml-env/bin/python scripts/export_coreml.py   # in WSL
cd ../iOS && scripts/sync_model.sh
```
