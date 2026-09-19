//
//  TaskGroup+Collated.swift
//  DeltaPreviews
//
//  Created by Riley Testut on 7/14/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import Playgrounds

protocol CollatedTaskResultsProtocol<Value, Error>
{
    associatedtype Value
    associatedtype Error: Swift.Error
    
    var values: [Value] { get }
    var errors: [Error] { get }
}

protocol ItemizedCollatedTaskResultsProtocol<Item, Value, Error>: CollatedTaskResultsProtocol
{
    associatedtype Item: Hashable
    
    var successes: [Item: Value] { get }
    var failures: [Item: Error] { get }
    
    subscript(_ item: Item) -> Result<Value, Error>? { get }
}

fileprivate struct CollatedTaskResults<Item: Hashable, Value, Error: Swift.Error>: ItemizedCollatedTaskResultsProtocol
{
    var successes: [Item: Value] {
        let successes = self.results.compactMapValues { result -> Value? in
            switch result {
            case .success(let value): return value
            case .failure: return nil
            }
        }
        return successes
    }
    
    var failures: [Item: Error] {
        let failures = self.results.compactMapValues { result -> Error? in
            switch result {
            case .success: return nil
            case .failure(let error): return error
            }
        }
        return failures
    }
    
    var values: [Value] {
        let values = self.successes.values
        return Array(values)
    }
    
    var errors: [Error] {
        let errors = self.failures.values
        return Array(errors)
    }
    
    subscript(_ item: Item) -> Result<Value, Error>? {
        get { self.results[item] }
        set { self.results[item] = newValue }
    }
    
    private var results = [Item: Result<Value, Error>]()
}

func withDefaultTaskGroup(
    isolation: isolated (any Actor)? = #isolation,
    body: (inout ThrowingTaskGroup<Void, any Swift.Error>) async -> Void) async throws
{
    try await withThrowingTaskGroup(of: Void.self, returning: Void.self, isolation: isolation) { taskGroup in
        await body(&taskGroup)
        
        for try await _ in taskGroup
        {
        }
    }
}

func withDefaultTaskGroup<Value>(
    of valueType: Value.Type = Value.self,
    isolation: isolated (any Actor)? = #isolation,
    body: (inout ThrowingTaskGroup<Value, any Swift.Error>) async -> Void) async throws -> [Value]
{
    try await withThrowingTaskGroup(of: Value.self, returning: [Value].self, isolation: isolation) { taskGroup in
        await body(&taskGroup)
        
        var values = [Value]()
        for try await value in taskGroup
        {
            values.append(value)
        }
        
        return values
    }
}

func withCollatingTaskGroup<Value>(
    of valueType: Value.Type = Value.self,
    isolation: isolated (any Actor)? = #isolation,
    body: (inout ThrowingTaskGroup<Value, any Swift.Error>) async -> Void) async -> some CollatedTaskResultsProtocol<Value, any Swift.Error>
{
    await withThrowingTaskGroup(of: Value.self,
                                returning: CollatedTaskResults<UUID, Value, Error>.self,
                                isolation: isolation) { taskGroup in
        await body(&taskGroup)
        
        var results = CollatedTaskResults<UUID, Value, Error>()
        while case let result? = await taskGroup.nextResult()
        {
            let uuid = UUID()
            
            do
            {
                let value = try result.get()
                results[uuid] = .success(value)
            }
            catch
            {
                results[uuid] = .failure(error)
            }
        }
        
        return results
    }
}

func withCollatingTaskGroup<Item: Hashable & Sendable, Value, Error: Swift.Error>(
    of valueType: Value.Type = Value.self,
    for items: some Sequence<Item>,
    isolation: isolated (any Actor)? = #isolation,
    body: @escaping (Item) async throws(Error) -> Value) async -> some ItemizedCollatedTaskResultsProtocol<Item, Value, Error>
{
    await withTaskGroup(of: (Item, Result<Value, Error>).self,
                        returning: CollatedTaskResults<Item, Value, Error>.self,
                        isolation: isolation) { taskGroup in
        var results = CollatedTaskResults<Item, Value, Error>()
        
        for item in items
        {
            _ = taskGroup.addTaskUnlessCancelled {
                do throws(Error)
                {
                    let value = try await body(item)
                    return (item, .success(value))
                }
                catch
                {
                    return (item, .failure(error))
                }
            }
        }
        
        for await (item, result) in taskGroup
        {
            results[item] = result
        }
        
        return results
    }
}
