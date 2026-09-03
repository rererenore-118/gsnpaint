// Google Drive へのサインインとファイルの保存・読み込みを担当するサービスクラス。
// google_sign_in + extension_google_sign_in_as_googleapis_auth + googleapis を使用。
//
// 読み書きの範囲は「マイドライブ直下のアプリ専用フォルダ（_appFolderName）の中だけ」に
// 限定している。ユーザーのDrive全体を触らせないための方針で、二重に担保している:
//   1. スコープが drive.file  … このアプリが作成したファイル以外はそもそも見えない
//   2. 問い合わせ先が専用フォルダ … 一覧・保存・上書きはすべてこのフォルダ配下のみ
// 以前はマイドライブのルート('root')を対象にしていたが、drive.file ではユーザーの
// 既存フォルダやファイルを列挙できないため、フォルダ一覧も既存ファイル一覧も空になっていた。

import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;

/// Drive 上のファイル・フォルダを表すシンプルな情報クラス
class DriveItem {
  final String id;
  final String name;
  final String? modifiedTime;

  const DriveItem({required this.id, required this.name, this.modifiedTime});
}

class GoogleDriveService {
  static const _mimeType = 'application/json';
  static const _folderMimeType = 'application/vnd.google-apps.folder';

  /// 保存先となるアプリ専用フォルダの名前（マイドライブ直下に自動作成される）。
  /// 保存ダイアログの案内文にも出すため公開している。
  static const appFolderName = 'GSNエディタ';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveFileScope],
  );

  GoogleSignInAccount? get currentUser => _googleSignIn.currentUser;
  bool get isSignedIn => _googleSignIn.currentUser != null;

  Stream<GoogleSignInAccount?> get onCurrentUserChanged =>
      _googleSignIn.onCurrentUserChanged;

  Future<GoogleSignInAccount?> signIn() async => await _googleSignIn.signIn();
  Future<void> signOut() async => await _googleSignIn.disconnect();
  Future<GoogleSignInAccount?> signInSilently() async =>
      await _googleSignIn.signInSilently();

  Future<drive.DriveApi?> _getDriveApi() async {
    final authClient = await _googleSignIn.authenticatedClient();
    if (authClient == null) return null;
    return drive.DriveApi(authClient);
  }

  /// アプリ専用フォルダのIDを返す。無ければマイドライブ直下に作成する。
  ///
  /// 名前だけで検索しているが、drive.file スコープでは「このアプリが作成した
  /// ファイル」しか見えないため、同名のユーザーフォルダにヒットすることはない。
  /// IDをキャッシュしないのは、ユーザーがDrive側でフォルダを削除したあとも
  /// 次の保存で作り直せるようにするため（消えたIDを掴んだままになるのを避ける）。
  Future<String> _ensureAppFolder(drive.DriveApi driveApi) async {
    final found = await driveApi.files.list(
      q: "mimeType='$_folderMimeType'"
          " and name='$appFolderName'"
          " and trashed=false",
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final existing = found.files;
    if (existing != null && existing.isNotEmpty) return existing.first.id!;

    // parents を指定しない場合はマイドライブ直下に作られる。
    final created = await driveApi.files.create(
      drive.File()
        ..name = appFolderName
        ..mimeType = _folderMimeType,
      $fields: 'id',
    );
    return created.id!;
  }

  /// アプリ専用フォルダ内の JSON ファイル一覧を返す（更新が新しい順）
  Future<List<DriveItem>> listJsonFiles() async {
    final driveApi = await _getDriveApi();
    if (driveApi == null) throw Exception('Drive API の取得に失敗しました。');

    final folderId = await _ensureAppFolder(driveApi);
    final result = await driveApi.files.list(
      q: "'$folderId' in parents"
          " and mimeType='$_mimeType'"
          " and trashed=false",
      spaces: 'drive',
      $fields: 'files(id, name, modifiedTime)',
      orderBy: 'modifiedTime desc',
    );
    return (result.files ?? [])
        .map((f) => DriveItem(
              id: f.id!,
              name: f.name!,
              modifiedTime: f.modifiedTime?.toIso8601String(),
            ))
        .toList();
  }

  /// アプリ専用フォルダにJSONを保存する。
  /// 同フォルダに同名ファイルがあれば上書き更新。
  Future<void> saveFile(String jsonContent, String fileName) async {
    final driveApi = await _getDriveApi();
    if (driveApi == null) throw Exception('Drive API の取得に失敗しました。');

    final folderId = await _ensureAppFolder(driveApi);

    // ファイル名に .json がなければ付ける
    final name = fileName.endsWith('.json') ? fileName : '$fileName.json';

    final contentBytes = utf8.encode(jsonContent);

    // 同フォルダ内に同名ファイルがあるか検索
    final existingId = await _findFileIdInFolder(driveApi, name, folderId);

    if (existingId != null) {
      await driveApi.files.update(
        drive.File(),
        existingId,
        uploadMedia: drive.Media(
          Stream.fromIterable([contentBytes]),
          contentBytes.length,
          contentType: _mimeType,
        ),
      );
    } else {
      final file = drive.File()
        ..name = name
        ..mimeType = _mimeType
        ..parents = [folderId];
      await driveApi.files.create(
        file,
        uploadMedia: drive.Media(
          Stream.fromIterable([contentBytes]),
          contentBytes.length,
          contentType: _mimeType,
        ),
      );
    }
  }

  /// ファイルIDを指定してJSONを読み込む
  Future<String> loadFileById(String fileId) async {
    final driveApi = await _getDriveApi();
    if (driveApi == null) throw Exception('Drive API の取得に失敗しました。');

    final response = await driveApi.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = await response.stream.fold<List<int>>(
      [],
      (prev, chunk) => prev..addAll(chunk),
    );
    return utf8.decode(bytes);
  }

  /// 指定フォルダ内で name に一致するファイルIDを返す（なければ null）
  Future<String?> _findFileIdInFolder(
      drive.DriveApi driveApi, String name, String folderId) async {
    final result = await driveApi.files.list(
      q: "'$folderId' in parents"
          " and name='$name'"
          " and mimeType='$_mimeType'"
          " and trashed=false",
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final files = result.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }
}
