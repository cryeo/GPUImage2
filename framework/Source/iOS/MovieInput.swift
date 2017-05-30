import AVFoundation

public let RotationFragmentShader = "varying highp vec2 textureCoordinate;\n uniform sampler2D inputImageTexture;\n uniform highp float angle;\n void main() {\n highp vec2 coord = textureCoordinate;\n highp float sin_factor = sin(angle);\n highp float cos_factor = cos(angle);\n coord = vec2(coord.x - 0.5, coord.y - 0.5) * mat2(cos_factor, sin_factor, -sin_factor, cos_factor);\n coord += 0.5;\n gl_FragColor = texture2D(inputImageTexture, coord);\n }\n"

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    let yuvConversionShader:ShaderProgram
    let rotationShader:ShaderProgram
    let asset:AVAsset
    let assetReader:AVAssetReader
    let playAtActualSpeed:Bool
    let loop:Bool
    var videoEncodingIsFinished = false
    var previousFrameTime = kCMTimeZero
    var previousActualFrameTime = CFAbsoluteTimeGetCurrent()

    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    
    var orientation: ImageOrientation = .portrait

    // TODO: Add movie reader synchronization
    // TODO: Someone will have to add back in the AVPlayerItem logic, because I don't know how that works
    public init(asset:AVAsset, playAtActualSpeed:Bool = false, loop:Bool = false) throws {
        self.asset = asset
        self.playAtActualSpeed = playAtActualSpeed
        self.loop = loop
        self.yuvConversionShader = crashOnShaderCompileFailure("MovieInput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
        self.rotationShader = crashOnShaderCompileFailure("MovieInput"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(1), fragmentShader:RotationFragmentShader)}
    
        assetReader = try AVAssetReader(asset:self.asset)
        
        let outputSettings:[String:AnyObject] = [(kCVPixelBufferPixelFormatTypeKey as String):NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
        let readerVideoTrackOutput = AVAssetReaderTrackOutput(track:self.asset.tracks(withMediaType: AVMediaTypeVideo)[0], outputSettings:outputSettings)
        readerVideoTrackOutput.alwaysCopiesSampleData = false
        assetReader.add(readerVideoTrackOutput)
        // TODO: Audio here
    }

    public convenience init(url:URL, playAtActualSpeed:Bool = false, loop:Bool = false) throws {
        let inputOptions = [AVURLAssetPreferPreciseDurationAndTimingKey:NSNumber(value:true)]
        let inputAsset = AVURLAsset(url:url, options:inputOptions)
        try self.init(asset:inputAsset, playAtActualSpeed:playAtActualSpeed, loop:loop)
    }

    public convenience init(asset:AVAsset, playAtActualSpeed:Bool = false, loop:Bool = false, orientation: ImageOrientation) throws {
        try self.init(asset:asset, playAtActualSpeed:playAtActualSpeed, loop:loop)
        self.orientation = orientation
    }

    // MARK: -
    // MARK: Playback control

    public func start(_ completionCallback:(() -> Void)? = nil) {
        asset.loadValuesAsynchronously(forKeys:["tracks"], completionHandler:{
            DispatchQueue.global(priority:DispatchQueue.GlobalQueuePriority.default).async(execute: {
                guard (self.asset.statusOfValue(forKey: "tracks", error:nil) == .loaded) else { return }

                guard self.assetReader.startReading() else {
                    print("Couldn't start reading")
                    return
                }
                
                var readerVideoTrackOutput:AVAssetReaderOutput? = nil;
                
                for output in self.assetReader.outputs {
                    if(output.mediaType == AVMediaTypeVideo) {
                        readerVideoTrackOutput = output;
                    }
                }
                
                while (self.assetReader.status == .reading) {
                    self.readNextVideoFrame(from:readerVideoTrackOutput!)
                }
                
                if (self.assetReader.status == .completed) {
                    self.assetReader.cancelReading()
                    
                    if (self.loop) {
                        // TODO: Restart movie processing
                    } else {
                        completionCallback?()
                        self.endProcessing()
                    }
                }
            })
        })
    }
    
    public func cancel() {
        assetReader.cancelReading()
        self.endProcessing()
    }
    
    func endProcessing() {
        
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func readNextVideoFrame(from videoTrackOutput:AVAssetReaderOutput) {
        if ((assetReader.status == .reading) && !videoEncodingIsFinished) {
            if let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
                if (playAtActualSpeed) {
                    // Do this outside of the video processing queue to not slow that down while waiting
                    let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
                    let differenceFromLastFrame = CMTimeSubtract(currentSampleTime, previousFrameTime)
                    let currentActualTime = CFAbsoluteTimeGetCurrent()
                    
                    let frameTimeDifference = CMTimeGetSeconds(differenceFromLastFrame)
                    let actualTimeDifference = currentActualTime - previousActualFrameTime
                    
                    if (frameTimeDifference > actualTimeDifference) {
                        usleep(UInt32(round(1000000.0 * (frameTimeDifference - actualTimeDifference))))
                    }
                    
                    previousFrameTime = currentSampleTime
                    previousActualFrameTime = CFAbsoluteTimeGetCurrent()
                }

                sharedImageProcessingContext.runOperationSynchronously{
                    self.process(movieFrame:sampleBuffer)
                    CMSampleBufferInvalidate(sampleBuffer)
                }
            } else {
                if (!loop) {
                    videoEncodingIsFinished = true
                    if (videoEncodingIsFinished) {
                        self.endProcessing()
                    }
                }
            }
        }
//        else if (synchronizedMovieWriter != nil) {
//            if (assetReader.status == .Completed) {
//                self.endProcessing()
//            }
//        }

    }
    
    func process(movieFrame frame:CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
    
//        processingFrameTime = currentSampleTime
        self.process(movieFrame:movieFrame, withSampleTime:currentSampleTime)
    }
    
    func process(movieFrame:CVPixelBuffer, withSampleTime:CMTime) {
        let bufferHeight = CVPixelBufferGetHeight(movieFrame)
        let bufferWidth = CVPixelBufferGetWidth(movieFrame)
        CVPixelBufferLockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))

        let conversionMatrix = colorConversionMatrix601FullRangeDefault
        // TODO: Get this color query working
//        if let colorAttachments = CVBufferGetAttachment(movieFrame, kCVImageBufferYCbCrMatrixKey, nil) {
//            if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == .EqualTo) {
//                _preferredConversion = kColorConversion601FullRange
//            } else {
//                _preferredConversion = kColorConversion709
//            }
//        } else {
//            _preferredConversion = kColorConversion601FullRange
//        }
        
        let startTime = CFAbsoluteTimeGetCurrent()

        let luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
        luminanceFramebuffer.lock()
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(movieFrame, 0))
        
        let chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
        chrominanceFramebuffer.lock()
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(movieFrame, 1))
        
        let movieFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
        movieFramebuffer.lock()
        
        convertYUVToRGB(shader:self.yuvConversionShader, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:movieFramebuffer, colorConversionMatrix:conversionMatrix)
        
        var resultBufferHeight: Int = 0
        var resultBufferWidth: Int = 0
        var rotationAngle: Float = 0
        
        switch (orientation) {
        case .portrait:
            resultBufferHeight = bufferWidth
            resultBufferWidth = bufferHeight
            rotationAngle = Float.pi / 2
        case .portraitUpsideDown:
            resultBufferHeight = bufferWidth
            resultBufferWidth = bufferHeight
            rotationAngle = -Float.pi / 2
        case .landscapeLeft:
            resultBufferWidth = bufferWidth
            resultBufferHeight = bufferHeight
            rotationAngle = Float.pi
        case .landscapeRight:
            resultBufferWidth = bufferWidth
            resultBufferHeight = bufferHeight
            rotationAngle = 0
        }
        
        let resultFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.portrait, size:GLSize(width:GLint(resultBufferWidth), height:GLint(resultBufferHeight)), textureOnly:false)
        resultFramebuffer.lock()
        
        let textureProperties:[InputTextureProperties]
        textureProperties = [movieFramebuffer.texturePropertiesForTargetOrientation(resultFramebuffer.orientation)]
        
        resultFramebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        var uniformSettings = ShaderUniformSettings()
        uniformSettings["angle"] = rotationAngle
        renderQuadWithShader(self.rotationShader, uniformSettings:uniformSettings, vertices:standardImageVertices, inputTextures:textureProperties)
        movieFramebuffer.unlock()
        resultFramebuffer.unlock()
        
        CVPixelBufferUnlockBaseAddress(movieFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        resultFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(withSampleTime))
        self.updateTargetsWithFramebuffer(resultFramebuffer)
        
        if self.runBenchmark {
            let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
            self.numberOfFramesCaptured += 1
            self.totalFrameTimeDuringCapture += currentFrameTime
            print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured)) ms")
            print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
    }

    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for movie inputs
    }
}
