import Foundation
import OSLog

@available(macOS 11.0, *)
public class TaskQueue{
    private class PendingTask{
        let label:String?
        var isCancelled = false
        init(label: String? = nil) {
            self.label = label
        }
    }
    private class AsyncTask : PendingTask {
        let continuation: CheckedContinuation<Any,Error>?
        let block: () async throws -> Any
        
        init(label: String?, continuation: CheckedContinuation<Any, Error>?, block: @escaping () async throws -> Any) {
            self.continuation = continuation
            self.block = block
            super.init(label: label)
        }
    }
    
    private class StreamTask : PendingTask{
        let continuation: AsyncThrowingStream<Any,Error>.Continuation
        let block: (AsyncThrowingStream<Any,Error>.Continuation) -> Void
        
        init(label: String?, continuation: AsyncThrowingStream<Any,Error>.Continuation, block: @escaping (AsyncThrowingStream<Any,Error>.Continuation) -> Void) {
            self.continuation = continuation
            self.block = block
            super.init(label: label)
        }
    }
    
    public let label:String?
    
    private let pendingTasksContinuation: AsyncStream<PendingTask>.Continuation
    
    private let pendingTasks: AsyncStream<PendingTask>
    
    private var scope: Task<Void,Never>?
        
    private func initScope()
    {
        scope = Task{
            for await pendingTask in pendingTasks
            {
                logger?.log("PendingTask \(pendingTask.label ?? "", privacy: .public) received")
                logger?.log("scope isCancelled \(Task.isCancelled)")
                if(Task.isCancelled){ break }
                if(pendingTask.isCancelled) { continue }
                if let task = pendingTask as? AsyncTask
                {
                    do{
                        logger?.log("AsyncTask \(pendingTask.label ?? "", privacy: .public) start")
                        let result = try await task.block()
                        logger?.log("AsyncTask \(pendingTask.label ?? "", privacy: .public) resume")
                        task.continuation?.resume(returning: result)
                    }
                    catch
                    {
                        logger?.error("AsyncTask \(pendingTask.label ?? "") error \(error)")
                        task.continuation?.resume(throwing: error)
                    }
                }
                else if let task = pendingTask as? StreamTask
                {
                    do
                    {
                        logger?.log("StreamTask \(pendingTask.label ?? "") start")
                        for try await value in AsyncThrowingStream(Any.self, task.block)
                        {
                            logger?.log("StreamTask \(pendingTask.label ?? "") yield")
                            task.continuation.yield(value)
                        }
                        logger?.log("StreamTask \(pendingTask.label ?? "") finish")
                        task.continuation.finish()
                    }
                    catch
                    {
                        logger?.error("StreamTask \(pendingTask.label ?? "") error \(error)")
                        task.continuation.finish(throwing: error)
                    }
                    
                }
                else
                {
                    logger?.log("PendingTask discard \(pendingTask.label ?? "")")
                }
                if(Task.isCancelled){ break }
            }
            for await pendingTask in pendingTasks
            {
                if let task = pendingTask as? AsyncTask
                {
                    task.continuation?.resume(throwing: CancellationError())
                }
                else if let task = pendingTask as? StreamTask
                {
                    task.continuation.finish(throwing: CancellationError())
                }
            }
        }
    }
    
    private var logger: Logger? = nil
    public init(label: String? = nil, debugLog: Bool = false) {
        self.label = label
        if debugLog {
            logger = Logger(
                subsystem: "rickymohk",
                category: label ?? "default"
            )
        }
        
        (pendingTasks, pendingTasksContinuation) = AsyncStream.makeStream()

        initScope()
    }
    
    public func close()
    {
        if let scope = scope,
           !scope.isCancelled
        {
            scope.cancel()
        }
    }
    
    public func dispatch(label:String?=nil,block: @escaping () async throws -> Void)
    {
        pendingTasksContinuation.yield(AsyncTask(label: label, continuation: nil, block: block))
    }
    
    public func dispatch<T>(label:String?=nil,block: @escaping () async throws -> T) async throws -> T
    {
        var pendingTask : AsyncTask?
        let cancel = {
            pendingTask?.isCancelled = true
        }
        return try await withTaskCancellationHandler {
            return (try await withCheckedThrowingContinuation({ continuation in
                let task = AsyncTask(label: label, continuation: continuation, block: block)
                pendingTask = task
                pendingTasksContinuation.yield(task)
            })) as! T
        } onCancel: {
            cancel()
        }
    }
    
    public func dispatchStream<T>( label:String?=nil, block:@escaping (AsyncThrowingStream<T,Error>.Continuation) -> Void) -> AsyncThrowingStream<T,Error>
    {
        let anyStream = AsyncThrowingStream<Any,Error> { continuation in
            pendingTasksContinuation.yield(StreamTask(label: label, continuation: continuation, block: { anyContinuation in
                Task{
                    do
                    {
                        for try await element in AsyncThrowingStream(T.self,block)
                        {
                            anyContinuation.yield(element)
                        }
                        anyContinuation.finish()
                    }
                    catch
                    {
                        anyContinuation.finish(throwing: error)
                    }
                }
            }))
        }
        return AsyncThrowingStream<T,Error> { typedContinuation in
            Task
            {
                do{
                    for try await element in anyStream
                    {
                        typedContinuation.yield(element as! T)
                    }
                    typedContinuation.finish()
                }
                catch
                {
                    typedContinuation.finish(throwing: error)
                }
            }
        }
    }
}
