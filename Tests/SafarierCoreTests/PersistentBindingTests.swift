import XCTest
import Foundation
import Darwin
import BinderIdentity
@testable import SafarierCore

final class PersistentBindingTests: XCTestCase {
    func testPersistentLegacyProfilePinsReferencedProxyAndRejectsMutation() async throws {
        let root=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-binding-test-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("locks"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let proxy=ProxySettings(name:"fixture",kind:.socks5,host:"example.invalid",port:1234)
        let profile=Profile(name:"fixture",mode:.persistent,proxyID:proxy.id,spi:.defaultFeatures,allowsBackgroundAutomation:false)
        func write<T:Codable & Sendable>(_ records:[T],_ filename:String) throws {
            let url=root.appendingPathComponent(filename);try JSONDocumentStore<T>.encode(records).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        try write([profile],"profiles.json");try write([proxy],"proxies.json")
        let workspace=SafarierWorkspace(root:root),spec=workspace.runnerSpec(for:profile,backgroundAutomation:true)
        let provider=try RepositoryBindingProvider.create(workspace:workspace,role:.controller,expectedSpec:spec,actualArgs:spec.arguments(),environment:spec.environment(inheriting:[:]),originalLock:nil)
        let first=try await provider.read(deadline:bi_deadline_after_ms(2999))
        XCTAssertEqual(first.profile,profile)
        var changed=proxy;changed.port=4321;try write([changed],"proxies.json")
        do { _=try await provider.read(deadline:bi_deadline_after_ms(2999));XCTFail("mutated outbound accepted") } catch { }
    }
    func testPersistentSubscriptionBindsExactNodeAndDetectsChange() async throws {
        let root=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-binding-test-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("locks"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let node=SubscriptionNode(name:"fixture",type:.socks,server:"example.invalid",serverPort:1234)
        var subscription=Subscription(name:"fixture",url:URL(string:"https://example.invalid")!,nodes:[node])
        let profile=Profile(name:"fixture",mode:.persistent,spi:.defaultFeatures,subscriptionID:subscription.id,nodeName:node.name,allowsBackgroundAutomation:false)
        func write<T:Codable & Sendable>(_ records:[T],_ filename:String) throws {
            let url=root.appendingPathComponent(filename);try JSONDocumentStore<T>.encode(records).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        try write([profile],"profiles.json");try write([subscription],"subscriptions.json")
        let workspace=SafarierWorkspace(root:root),spec=workspace.runnerSpec(for:profile,backgroundAutomation:true)
        let provider=try RepositoryBindingProvider.create(workspace:workspace,role:.controller,expectedSpec:spec,actualArgs:spec.arguments(),environment:spec.environment(inheriting:[:]),originalLock:nil)
        let first=try await provider.read(deadline:bi_deadline_after_ms(2999))
        XCTAssertEqual(first.node,node);XCTAssertEqual(first.subscription,subscription)
        subscription.nodes[0].serverPort=4321;try write([subscription],"subscriptions.json")
        do { _=try await provider.read(deadline:bi_deadline_after_ms(2999));XCTFail("mutated subscription accepted") } catch { }
    }

}
