{{flutter_js}}
{{flutter_build_config}}

// Service Worker は登録しない。Flutter 既定の Service Worker はアプリ本体をブラウザに保存するため、
// デプロイ後も利用者に古い版が表示され続けることがあった（オフライン対応は不要）。
_flutter.loader.load();
