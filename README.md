# Smishing Shield PH

Flutter project for SMS smishing detection, quarantine handling, online chat,
and Android default-SMS integration.

## Local model setup

The DistilBERT TFLite model is stored in this repository with Git LFS. After
cloning, make sure LFS content is available before running the app:

`git lfs pull`

The expected model path is:

`assets/distilbert_model.tflite`

Tokenizer and config files are also part of the repo:

- `assets/config.json`
- `assets/tokenizer.json`
- `assets/tokenizer_config.json`
- `assets/vocab.txt`

## Getting started

1. Install Flutter.
2. Run `flutter pub get`.
3. Run `git lfs pull` after cloning to download the model file.
4. Run `flutter analyze` and `flutter run`.
