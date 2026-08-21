import Contacts
import Foundation

final class ContactsSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .contacts
    private let store = CNContactStore()

    func status() async -> SourceStatus {
        let permission = Self.permission(for: CNContactStore.authorizationStatus(for: .contacts))
        return SourceStatus(source: source, permission: permission, indexedCount: 0, isIndexing: false, message: permission == .authorized ? nil : "Contacts are only read after you allow access.")
    }

    func requestAccess() async -> SourceStatus {
        do { _ = try await store.requestAccess(for: .contacts) }
        catch { return SourceStatus(source: source, permission: .denied, indexedCount: 0, isIndexing: false, message: error.localizedDescription) }
        return await status()
    }

    func fetchRecords() async throws -> [IndexedRecord] {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Allow Contacts access in System Settings.") }
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as NSString,
            CNContactNamePrefixKey as NSString,
            CNContactGivenNameKey as NSString,
            CNContactMiddleNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactNameSuffixKey as NSString,
            CNContactNicknameKey as NSString,
            CNContactOrganizationNameKey as NSString,
            CNContactEmailAddressesKey as NSString,
            CNContactPhoneNumbersKey as NSString
        ]
        var result: [IndexedRecord] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keysToFetch)) { contact, _ in
            let emails = contact.emailAddresses.map(\.value).map(String.init)
            let phoneNumbers = contact.phoneNumbers.map(\.value.stringValue)
            let handles = emails + phoneNumbers
            let name = Self.displayName(for: contact, fallbackHandles: handles)
            let aliases = ([contact.nickname] + handles).filter { !$0.isEmpty }
            result.append(IndexedRecord(id: "contact-\(contact.identifier)", source: .contacts, title: name, body: aliases.joined(separator: "\n"), author: name, participants: handles, timestamp: .distantPast, url: nil, threadID: nil))
        }
        return result
    }

    static func displayName(for contact: CNContact, fallbackHandles: [String] = []) -> String {
        var components = PersonNameComponents()
        components.namePrefix = contact.namePrefix
        components.givenName = contact.givenName
        components.middleName = contact.middleName
        components.familyName = contact.familyName
        components.nameSuffix = contact.nameSuffix
        let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .long)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [formatted, contact.nickname, contact.organizationName]
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? fallbackHandles.first(where: { !$0.isEmpty })
            ?? contact.identifier
    }

    private static func permission(for status: CNAuthorizationStatus) -> SourcePermission {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }
}
