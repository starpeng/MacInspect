import Foundation
import Metal

/// Continuous Metal compute stress until `cancel()` is called.
final class MetalStressEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var queue: DispatchQueue?

    var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    var deviceName: String? {
        MTLCreateSystemDefaultDevice()?.name
    }

    func start() {
        lock.lock()
        cancelled = false
        lock.unlock()

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { return }

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void stress(device float *buf [[buffer(0)]],
                           uint id [[thread_position_in_grid]]) {
            float x = buf[id];
            for (int i = 0; i < 64; ++i) {
                x = x * 1.000001f + 0.000001f;
                x = sqrt(x * x + 1.0f);
            }
            buf[id] = x;
        }
        """

        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "stress"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return }

        let count = 1 << 20 // 1M floats ≈ 4 MB
        guard let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return }
        memset(buffer.contents(), 0, buffer.length)

        let q = DispatchQueue(label: "MacInspect.MetalStress", qos: .userInitiated)
        lock.lock()
        queue = q
        lock.unlock()

        let threadWidth = pipeline.threadExecutionWidth
        let threadsPerGroup = MTLSize(width: threadWidth, height: 1, depth: 1)
        let threadgroups = MTLSize(
            width: (count + threadWidth - 1) / threadWidth,
            height: 1,
            depth: 1
        )

        // Keep a few command buffers in flight so GPU stays busy (wait-each-frame under-reports %).
        let inFlight = DispatchSemaphore(value: 3)

        q.async { [weak self] in
            while true {
                self?.lock.lock()
                let stop = self?.cancelled ?? true
                self?.lock.unlock()
                if stop { break }

                inFlight.wait()
                self?.lock.lock()
                let stopAfterWait = self?.cancelled ?? true
                self?.lock.unlock()
                if stopAfterWait {
                    inFlight.signal()
                    break
                }

                guard let cmd = commandQueue.makeCommandBuffer(),
                      let encoder = cmd.makeComputeCommandEncoder()
                else {
                    inFlight.signal()
                    break
                }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                encoder.endEncoding()
                cmd.addCompletedHandler { _ in inFlight.signal() }
                cmd.commit()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
