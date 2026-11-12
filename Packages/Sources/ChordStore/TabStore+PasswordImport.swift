import ChordCore
import ChordSecrets
import Foundation

/// File → Import Passwords…: the store's half.
///
/// The work lives in `ChromiumPasswordImporter`; this only supplies the vault,
/// refuses private windows, and refreshes the fill key after a write so a
/// freshly imported login is offered without navigating.
extension TabStore {

    /// Reads and dry-runs a picked `Login Data` file. Writes nothing.
    public func previewPasswordImport(
        from url: URL, in window: WindowState, browser: ChromiumBrowser? = nil
    ) async -> Result<ChromiumPasswordImportPreview, ChromiumPasswordImportError> {
        guard !window.isPrivate else { return .failure(.privateWindow) }
        guard let vault else { return .failure(.vaultUnavailable) }
        let importer = ChromiumPasswordImporter(
            vault: vault, keyProvider: ChromiumSafeStorageKeychain()
        )
        do {
            return .success(
                try await importer.preview(loginDataAt: url, browser: browser)
            )
        } catch let error as ChromiumPasswordImportError {
            return .failure(error)
        } catch {
            return .failure(.databaseUnreadable(.invalidDatabase))
        }
    }

    /// Applies a preview the user confirmed. This is the only write path.
    public func applyPasswordImport(
        _ preview: ChromiumPasswordImportPreview
    ) async -> ChromiumPasswordImportResult {
        guard let vault else {
            preview.invalidate()
            return ChromiumPasswordImportResult(
                importedWithSecret: 0, importedUsernameOnly: 0,
                alreadyPresent: preview.alreadyPresentCount,
                skipped: preview.skippedCount,
                undecryptable: preview.undecryptableCount,
                failed: preview.importCount
            )
        }
        let importer = ChromiumPasswordImporter(
            vault: vault, keyProvider: ChromiumSafeStorageKeychain()
        )
        let result = await importer.apply(preview)
        // A saved credential should be offered on pages already open; the fill
        // affordance is computed from the vault, not re-read on navigation.
        refreshFillableCredentialsEverywhere()
        return result
    }
}
