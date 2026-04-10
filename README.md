# Smishing Shield PH

Flutter project for SMS smishing detection, quarantine handling, online chat,
and Android default-SMS integration.

## Local model setup

The DistilBERT TFLite model is intentionally not committed to this repository
because GitHub rejects files larger than 100 MB. To run the on-device detector
locally, place your trained model file at:

`assets/distilbert_model.tflite`

The tokenizer and config files remain in the repo:

- `assets/config.json`
- `assets/tokenizer.json`
- `assets/tokenizer_config.json`
- `assets/vocab.txt`

## Getting started

1. Install Flutter.
2. Run `flutter pub get`.
3. Add the local TFLite model file if you want on-device classification.
4. Run `flutter analyze` and `flutter run`.
