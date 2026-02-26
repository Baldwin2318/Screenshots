# Screenshots (iOS)

Local-first screenshot search app with on-device CLIP semantic search (CoreML + Apple Neural Engine) and Hugging Face tokenizer support.

## Developer Setup (After Clone)

Follow these steps after cloning the repo to enable full CLIP semantic search.

### 1. Open the project

Open:

- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Screenshots.xcodeproj`

### 2. Resolve Swift package dependencies

The project uses `swift-transformers` (`Tokenizers` product).

In Xcode:

1. `File` -> `Packages` -> `Resolve Package Versions`
2. Wait for package resolution to finish

Note: The project is configured to use `swift-transformers` with an `upToNextMinorVersion` rule from `1.1.8`.

### 3. Download Apple MobileCLIP S2 CoreML models

Get the models from Hugging Face:

- [apple/coreml-mobileclip](https://huggingface.co/apple/coreml-mobileclip)

You need these two files:

- `mobileclip_s2_image.mlpackage`
- `mobileclip_s2_text.mlpackage`

Optional CLI download example:

```bash
mkdir -p /tmp/mobileclip
huggingface-cli download apple/coreml-mobileclip --local-dir /tmp/mobileclip
find /tmp/mobileclip -name "mobileclip_s2_*.mlpackage"
```

### 4. Place the models in the project (required)

Copy the two model packages into:

- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Screenshots/Models/CLIP/mobileclip_s2_image.mlpackage`
- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Screenshots/Models/CLIP/mobileclip_s2_text.mlpackage`

If the `CLIP` folder does not exist, create it:

- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Screenshots/Models/CLIP`

### 5. Add the models to Xcode target membership

In Xcode:

1. Drag both `.mlpackage` folders into the project navigator (recommended group: `Screenshots/Models/CLIP`)
2. Check `Copy items if needed`
3. Make sure target membership includes `Screenshots`

Xcode will compile the `.mlpackage` files into `.mlmodelc` at build time.

### 6. Confirm tokenizer files exist (required for text encoder path)

These files should exist in the repo and be included in the app target:

- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Tokenizer/tokenizer.json`
- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Tokenizer/tokenizer_config.json`

If they are missing, get a matching tokenizer for the MobileCLIP text model and place them in:

- `/Users/baldwinkielmalabanan/Desktop/SW_SC/IOS/Screenshots/Tokenizer/`

### 7. Build and run

In Xcode:

1. Select the `Screenshots` scheme
2. Run on device or simulator
3. Grant Photos access
4. Trigger sync/import to generate embeddings

### 8. Verify CLIP runtime + tokenizer logs (recommended)

In Xcode console, filter for:

- `CLIPTokenizer`
- `CLIPEmbeddingService`
- `CLIPRuntime`

Healthy startup logs typically include:

- tokenizer loaded / registered
- CLIP contract resolved
- CLIP runtime initialized

### 9. Test semantic search

Example checks:

- Screenshot contains a puppy
- Search `dog`
- Search `puppy`
- Search `small animal`

Expected: the puppy screenshot should appear in results after indexing completes.

## Notes

- The CLIP model packages are intentionally gitignored because they are too large for normal GitHub pushes.
- If semantic search appears to behave like simple keyword search, confirm:
  - models are added to target membership
  - tokenizer files are in the app bundle
  - indexing/backfill has completed
