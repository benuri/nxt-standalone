// Copyright 2017 The NXT Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "MetalBackend.h"

#include <spirv-cross/spirv_msl.hpp>

#include <sstream>

#include "common/Commands.h"

namespace backend {
namespace metal {
    nxtProcTable GetNonValidatingProcs();
    nxtProcTable GetValidatingProcs();

    void Init(id<MTLDevice> metalDevice, nxtProcTable* procs, nxtDevice* device) {
        *device = nullptr;

        *procs = GetValidatingProcs();
        *device = reinterpret_cast<nxtDevice>(new Device(metalDevice));
    }

    void SetNextDrawable(nxtDevice device, id<CAMetalDrawable> drawable) {
        Device* backendDevice = reinterpret_cast<Device*>(device);
        backendDevice->SetNextDrawable(drawable);
    }

    void Present(nxtDevice device) {
        Device* backendDevice = reinterpret_cast<Device*>(device);
        backendDevice->Present();
    }

    // Device

    Device::Device(id<MTLDevice> mtlDevice) : mtlDevice(mtlDevice) {
        [mtlDevice retain];
        commandQueue = [mtlDevice newCommandQueue];
    }

    Device::~Device() {
        [mtlDevice release];
        mtlDevice = nil;

        [commandQueue release];
        commandQueue = nil;

        [currentTexture release];
        currentTexture = nil;

        [currentDepthTexture release];
        currentDepthTexture = nil;
    }

    BindGroupBase* Device::CreateBindGroup(BindGroupBuilder* builder) {
        return new BindGroup(this, builder);
    }
    BindGroupLayoutBase* Device::CreateBindGroupLayout(BindGroupLayoutBuilder* builder) {
        return new BindGroupLayout(this, builder);
    }
    BufferBase* Device::CreateBuffer(BufferBuilder* builder) {
        return new Buffer(this, builder);
    }
    BufferViewBase* Device::CreateBufferView(BufferViewBuilder* builder) {
        return new BufferView(this, builder);
    }
    CommandBufferBase* Device::CreateCommandBuffer(CommandBufferBuilder* builder) {
        return new CommandBuffer(this, builder);
    }
    InputStateBase* Device::CreateInputState(InputStateBuilder* builder) {
        return new InputState(this, builder);
    }
    PipelineBase* Device::CreatePipeline(PipelineBuilder* builder) {
        return new Pipeline(this, builder);
    }
    PipelineLayoutBase* Device::CreatePipelineLayout(PipelineLayoutBuilder* builder) {
        return new PipelineLayout(this, builder);
    }
    QueueBase* Device::CreateQueue(QueueBuilder* builder) {
        return new Queue(this, builder);
    }
    SamplerBase* Device::CreateSampler(SamplerBuilder* builder) {
        return new Sampler(this, builder);
    }
    ShaderModuleBase* Device::CreateShaderModule(ShaderModuleBuilder* builder) {
        return new ShaderModule(this, builder);
    }
    TextureBase* Device::CreateTexture(TextureBuilder* builder) {
        return new Texture(this, builder);
    }
    TextureViewBase* Device::CreateTextureView(TextureViewBuilder* builder) {
        return new TextureView(this, builder);
    }

    void Device::SetNextDrawable(id<CAMetalDrawable> drawable) {
        [currentDrawable release];
        currentDrawable = drawable;
        [currentDrawable retain];

        [currentTexture release];
        currentTexture = drawable.texture;
        [currentTexture retain];

        if (currentDepthTexture == nil ||
                currentTexture.width != currentDepthTexture.width ||
                currentTexture.height != currentDepthTexture.height) {
            if (currentDepthTexture != nil) {
                [currentDepthTexture release];
            }
            MTLTextureDescriptor* depthDescriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                width:currentTexture.width
                height:currentTexture.height
                mipmapped:NO];
            depthDescriptor.textureType = MTLTextureType2D;
            depthDescriptor.usage = MTLTextureUsageRenderTarget;
            depthDescriptor.storageMode = MTLStorageModePrivate;
            currentDepthTexture = [mtlDevice newTextureWithDescriptor:depthDescriptor];
        }

        MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        passDescriptor.colorAttachments[0].texture = currentTexture;
        passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        passDescriptor.depthAttachment.texture = currentDepthTexture;
        passDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        passDescriptor.depthAttachment.clearDepth = 1.0;


        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer
            renderCommandEncoderWithDescriptor:passDescriptor];
        [commandEncoder endEncoding];
        [commandBuffer commit];
    }

    void Device::Present() {
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        [commandBuffer presentDrawable: currentDrawable];
        [commandBuffer commit];
    }

    id<MTLDevice> Device::GetMTLDevice() {
        return mtlDevice;
    }

    id<MTLTexture> Device::GetCurrentTexture() {
        return currentTexture;
    }

    id<MTLTexture> Device::GetCurrentDepthTexture() {
        return currentDepthTexture;
    }

    void Device::Reference() {
    }

    void Device::Release() {
    }

    // Bind Group

    BindGroup::BindGroup(Device* device, BindGroupBuilder* builder)
        : BindGroupBase(builder), device(device) {
    }

    // Bind Group Layout

    BindGroupLayout::BindGroupLayout(Device* device, BindGroupLayoutBuilder* builder)
        : BindGroupLayoutBase(builder), device(device) {
    }

    // Buffer

    Buffer::Buffer(Device* device, BufferBuilder* builder)
        : BufferBase(builder), device(device) {
        mtlBuffer = [device->GetMTLDevice() newBufferWithLength:GetSize()
            options:MTLResourceStorageModeManaged];
    }

    Buffer::~Buffer() {
        std::lock_guard<std::mutex> lock(mutex);
        [mtlBuffer release];
        mtlBuffer = nil;
    }

    id<MTLBuffer> Buffer::GetMTLBuffer() {
        return mtlBuffer;
    }

    std::mutex& Buffer::GetMutex() {
        return mutex;
    }

    void Buffer::SetSubDataImpl(uint32_t start, uint32_t count, const uint32_t* data) {
        uint32_t* dest = reinterpret_cast<uint32_t*>([mtlBuffer contents]);
        {
            std::lock_guard<std::mutex> lock(mutex);
            memcpy(&dest[start], data, count * sizeof(uint32_t));
        }
        [mtlBuffer didModifyRange:NSMakeRange(start * sizeof(uint32_t), count * sizeof(uint32_t))];
    }

    // BufferView

    BufferView::BufferView(Device* device, BufferViewBuilder* builder)
        : BufferViewBase(builder), device(device) {
    }

    // CommandBuffer

    static MTLIndexType IndexFormatType(nxt::IndexFormat format) {
        switch (format) {
            case nxt::IndexFormat::Uint16:
                return MTLIndexTypeUInt16;
            case nxt::IndexFormat::Uint32:
                return MTLIndexTypeUInt32;
        }
    }

    CommandBuffer::CommandBuffer(Device* device, CommandBufferBuilder* builder)
        : CommandBufferBase(builder), device(device), commands(builder->AcquireCommands()) {
    }

    CommandBuffer::~CommandBuffer() {
        FreeCommands(&commands);
    }

    namespace {

        struct CurrentEncoders {
            Device* device;

            id<MTLBlitCommandEncoder> blit = nil;
            id<MTLComputeCommandEncoder> compute = nil;
            id<MTLRenderCommandEncoder> render = nil;

            void FinishEncoders() {
                if (blit != nil) {
                    [blit endEncoding];
                    blit = nil;
                }
                if (compute != nil) {
                    [compute endEncoding];
                    compute = nil;
                }
                if (render != nil) {
                    [render endEncoding];
                    render = nil;
                }
            }

            void EnsureBlit(id<MTLCommandBuffer> commandBuffer) {
                if (blit == nil) {
                    FinishEncoders();
                    blit = [commandBuffer blitCommandEncoder];
                }
            }
            void EnsureCompute(id<MTLCommandBuffer> commandBuffer) {
                if (compute == nil) {
                    FinishEncoders();
                    compute = [commandBuffer computeCommandEncoder];
                    // TODO(cwallez@chromium.org): does any state need to be reset?
                }
            }
            void EnsureRender(id<MTLCommandBuffer> commandBuffer) {
                if (render == nil) {
                    FinishEncoders();

                    // TODO(cwallez@chromium.org): this should be created from a renderpass subpass
                    MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                    descriptor.colorAttachments[0].texture = device->GetCurrentTexture();
                    descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
                    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
                    descriptor.depthAttachment.texture = device->GetCurrentDepthTexture();
                    descriptor.depthAttachment.loadAction = MTLLoadActionLoad;
                    descriptor.depthAttachment.storeAction = MTLStoreActionStore;

                    render = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
                    // TODO(cwallez@chromium.org): does any state need to be reset?
                }
            }
        };

    }

    void CommandBuffer::FillCommands(id<MTLCommandBuffer> commandBuffer, std::unordered_set<std::mutex*>* mutexes) {
        Command type;
        Pipeline* lastPipeline = nullptr;
        id<MTLBuffer> indexBuffer = nil;
        uint32_t indexBufferOffset = 0;
        MTLIndexType indexType = MTLIndexTypeUInt32;

        CurrentEncoders encoders;
        encoders.device = device;

        while (commands.NextCommandId(&type)) {
            switch (type) {
                case Command::CopyBufferToTexture:
                    {
                        CopyBufferToTextureCmd* copy = commands.NextCommand<CopyBufferToTextureCmd>();
                        Buffer* buffer = ToBackend(copy->buffer.Get());
                        Texture* texture = ToBackend(copy->texture.Get());

                        // TODO(kainino@chromium.org): this has to be in a Blit encoder, not a Render encoder, so ordering is lost here
                        unsigned rowSize = copy->width * TextureFormatPixelSize(texture->GetFormat());
                        MTLOrigin origin;
                        origin.x = copy->x;
                        origin.y = copy->y;
                        origin.z = copy->z;

                        MTLSize size;
                        size.width = copy->width;
                        size.height = copy->height;
                        size.depth = copy->depth;

                        encoders.EnsureBlit(commandBuffer);
                        [encoders.blit
                            copyFromBuffer:buffer->GetMTLBuffer()
                            sourceOffset:0
                            sourceBytesPerRow:rowSize
                            sourceBytesPerImage:(rowSize * copy->height)
                            sourceSize:size
                            toTexture:texture->GetMTLTexture()
                            destinationSlice:0
                            destinationLevel:copy->level
                            destinationOrigin:origin];
                    }
                    break;

                case Command::Dispatch:
                    {
                        DispatchCmd* dispatch = commands.NextCommand<DispatchCmd>();
                        encoders.EnsureCompute(commandBuffer);
                        ASSERT(lastPipeline->IsCompute());

                        [encoders.compute dispatchThreadgroups:MTLSizeMake(dispatch->x, dispatch->y, dispatch->z)
                            threadsPerThreadgroup: lastPipeline->GetLocalWorkGroupSize()];
                    }
                    break;

                case Command::DrawArrays:
                    {
                        DrawArraysCmd* draw = commands.NextCommand<DrawArraysCmd>();

                        encoders.EnsureRender(commandBuffer);
                        [encoders.render
                            drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:draw->firstVertex
                            vertexCount:draw->vertexCount
                            instanceCount:draw->instanceCount
                            baseInstance:draw->firstInstance];
                    }
                    break;

                case Command::DrawElements:
                    {
                        DrawElementsCmd* draw = commands.NextCommand<DrawElementsCmd>();

                        encoders.EnsureRender(commandBuffer);
                        [encoders.render
                            drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:draw->indexCount
                            indexType:indexType
                            indexBuffer:indexBuffer
                            indexBufferOffset:indexBufferOffset
                            instanceCount:draw->instanceCount
                            baseVertex:0
                            baseInstance:draw->firstInstance];
                    }
                    break;

                case Command::SetPipeline:
                    {
                        SetPipelineCmd* cmd = commands.NextCommand<SetPipelineCmd>();
                        lastPipeline = ToBackend(cmd->pipeline).Get();

                        if (lastPipeline->IsCompute()) {
                            encoders.EnsureCompute(commandBuffer);
                            lastPipeline->Encode(encoders.compute);
                        } else {
                            encoders.EnsureRender(commandBuffer);
                            lastPipeline->Encode(encoders.render);
                        }
                    }
                    break;

                case Command::SetPushConstants:
                    {
                        SetPushConstantsCmd* cmd = commands.NextCommand<SetPushConstantsCmd>();
                        uint32_t* valuesUInt = commands.NextData<uint32_t>(cmd->count);
                        int32_t* valuesInt = reinterpret_cast<int32_t*>(valuesUInt);
                        float* valuesFloat = reinterpret_cast<float*>(valuesUInt);

                        // TODO(kainino@chromium.org): implement SetPushConstants
                    }
                    break;

                case Command::SetBindGroup:
                    {
                        SetBindGroupCmd* cmd = commands.NextCommand<SetBindGroupCmd>();
                        BindGroup* group = ToBackend(cmd->group.Get());
                        uint32_t groupIndex = cmd->index;

                        const auto& layout = group->GetLayout()->GetBindingInfo();

                        if (lastPipeline->IsCompute()) {
                            encoders.EnsureCompute(commandBuffer);
                        } else {
                            encoders.EnsureRender(commandBuffer);
                        }

                        // TODO(kainino@chromium.org): Maintain buffers and offsets arrays in BindGroup so that we
                        // only have to do one setVertexBuffers and one setFragmentBuffers call here.
                        for (size_t binding = 0; binding < layout.mask.size(); ++binding) {
                            if (!layout.mask[binding]) {
                                continue;
                            }

                            auto stage = layout.visibilities[binding];
                            bool vertStage = stage & nxt::ShaderStageBit::Vertex;
                            bool fragStage = stage & nxt::ShaderStageBit::Fragment;
                            bool computeStage = stage & nxt::ShaderStageBit::Compute;
                            uint32_t vertIndex = 0;
                            uint32_t fragIndex = 0;
                            uint32_t computeIndex = 0;
                            if (vertStage) {
                                vertIndex = ToBackend(lastPipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Vertex)[groupIndex][binding];
                            }
                            if (fragStage) {
                                fragIndex = ToBackend(lastPipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Fragment)[groupIndex][binding];
                            }
                            if (computeStage) {
                                computeIndex = ToBackend(lastPipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Compute)[groupIndex][binding];
                            }

                            switch (layout.types[binding]) {
                                case nxt::BindingType::UniformBuffer:
                                case nxt::BindingType::StorageBuffer:
                                    {
                                        BufferView* view = ToBackend(group->GetBindingAsBufferView(binding));
                                        auto b = ToBackend(view->GetBuffer());
                                        mutexes->insert(&b->GetMutex());
                                        const id<MTLBuffer> buffer = b->GetMTLBuffer();
                                        const NSUInteger offset = view->GetOffset();
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(vertIndex, 1)];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(fragIndex, 1)];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(computeIndex, 1)];
                                        }

                                    }
                                    break;

                                case nxt::BindingType::Sampler:
                                    {
                                        auto sampler = ToBackend(group->GetBindingAsSampler(binding));
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:vertIndex];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:fragIndex];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:computeIndex];
                                        }
                                    }
                                    break;

                                case nxt::BindingType::SampledTexture:
                                    {
                                        auto texture = ToBackend(group->GetBindingAsTextureView(binding)->GetTexture());
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexTexture:texture->GetMTLTexture()
                                                atIndex:vertIndex];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentTexture:texture->GetMTLTexture()
                                                atIndex:fragIndex];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setTexture:texture->GetMTLTexture()
                                                atIndex:computeIndex];
                                        }
                                    }
                                    break;
                            }
                        }
                    }
                    break;

                case Command::SetIndexBuffer:
                    {
                        SetIndexBufferCmd* cmd = commands.NextCommand<SetIndexBufferCmd>();
                        auto b = ToBackend(cmd->buffer.Get());
                        mutexes->insert(&b->GetMutex());
                        indexBuffer = b->GetMTLBuffer();
                        indexBufferOffset = cmd->offset;
                        indexType = IndexFormatType(cmd->format);
                    }
                    break;

                case Command::SetVertexBuffers:
                    {
                        SetVertexBuffersCmd* cmd = commands.NextCommand<SetVertexBuffersCmd>();
                        auto buffers = commands.NextData<Ref<BufferBase>>(cmd->count);
                        auto offsets = commands.NextData<uint32_t>(cmd->count);

                        auto inputState = lastPipeline->GetInputState();

                        std::array<id<MTLBuffer>, kMaxVertexInputs> mtlBuffers;
                        std::array<NSUInteger, kMaxVertexInputs> mtlOffsets;

                        // Perhaps an "array of vertex buffers(+offsets?)" should be
                        // a NXT API primitive to avoid reconstructing this array?
                        for (uint32_t i = 0; i < cmd->count; ++i) {
                            Buffer* buffer = ToBackend(buffers[i].Get());
                            mutexes->insert(&buffer->GetMutex());
                            mtlBuffers[i] = buffer->GetMTLBuffer();
                            mtlOffsets[i] = offsets[i];
                        }

                        encoders.EnsureRender(commandBuffer);
                        [encoders.render
                            setVertexBuffers:mtlBuffers.data()
                            offsets:mtlOffsets.data()
                            withRange:NSMakeRange(kMaxBindingsPerGroup + cmd->startSlot, cmd->count)];
                    }
                    break;

                case Command::TransitionBufferUsage:
                    {
                        TransitionBufferUsageCmd* cmd = commands.NextCommand<TransitionBufferUsageCmd>();

                        cmd->buffer->TransitionUsageImpl(cmd->usage);
                    }
                    break;

                case Command::TransitionTextureUsage:
                    {
                        TransitionTextureUsageCmd* cmd = commands.NextCommand<TransitionTextureUsageCmd>();

                        cmd->texture->TransitionUsageImpl(cmd->usage);
                    }
                    break;
;
            }
        }

        encoders.FinishEncoders();
    }

    // InputState

    static MTLVertexFormat VertexFormatType(nxt::VertexFormat format) {
        switch (format) {
            case nxt::VertexFormat::FloatR32G32B32A32:
                return MTLVertexFormatFloat4;
            case nxt::VertexFormat::FloatR32G32B32:
                return MTLVertexFormatFloat3;
            case nxt::VertexFormat::FloatR32G32:
                return MTLVertexFormatFloat2;
        }
    }

    static MTLVertexStepFunction InputStepModeFunction(nxt::InputStepMode mode) {
        switch (mode) {
            case nxt::InputStepMode::Vertex:
                return MTLVertexStepFunctionPerVertex;
            case nxt::InputStepMode::Instance:
                return MTLVertexStepFunctionPerInstance;
        }
    }

    InputState::InputState(Device* device, InputStateBuilder* builder)
        : InputStateBase(builder), device(device) {
        mtlVertexDescriptor = [MTLVertexDescriptor new];

        const auto& attributesSetMask = GetAttributesSetMask();
        for (size_t i = 0; i < attributesSetMask.size(); ++i) {
            if (!attributesSetMask[i]) {
                continue;
            }
            const AttributeInfo& info = GetAttribute(i);

            auto attribDesc = [MTLVertexAttributeDescriptor new];
            attribDesc.format = VertexFormatType(info.format);
            attribDesc.offset = info.offset;
            attribDesc.bufferIndex = kMaxBindingsPerGroup + info.bindingSlot;
            mtlVertexDescriptor.attributes[i] = attribDesc;
            [attribDesc release];
        }

        const auto& inputsSetMask = GetInputsSetMask();
        for (size_t i = 0; i < inputsSetMask.size(); ++i) {
            if (!inputsSetMask[i]) {
                continue;
            }
            const InputInfo& info = GetInput(i);

            auto layoutDesc = [MTLVertexBufferLayoutDescriptor new];
            if (info.stride == 0) {
                // For MTLVertexStepFunctionConstant, the stepRate must be 0,
                // but the stride must NOT be 0, so I made up a value (256).
                layoutDesc.stepFunction = MTLVertexStepFunctionConstant;
                layoutDesc.stepRate = 0;
                layoutDesc.stride = 256;
            } else {
                layoutDesc.stepFunction = InputStepModeFunction(info.stepMode);
                layoutDesc.stepRate = 1;
                layoutDesc.stride = info.stride;
            }
            mtlVertexDescriptor.layouts[kMaxBindingsPerGroup + i] = layoutDesc;
            [layoutDesc release];
        }
    }

    InputState::~InputState() {
        [mtlVertexDescriptor release];
        mtlVertexDescriptor = nil;
    }

    MTLVertexDescriptor* InputState::GetMTLVertexDescriptor() {
        return mtlVertexDescriptor;
    }

    // Pipeline

    Pipeline::Pipeline(Device* device, PipelineBuilder* builder)
        : PipelineBase(builder), device(device) {

        if (IsCompute()) {
            const auto& module = ToBackend(builder->GetStageInfo(nxt::ShaderStage::Compute).module);
            const auto& entryPoint = builder->GetStageInfo(nxt::ShaderStage::Compute).entryPoint;

            id<MTLFunction> function = module->GetFunction(entryPoint.c_str());

            NSError *error = nil;
            mtlComputePipelineState = [device->GetMTLDevice()
                newComputePipelineStateWithFunction:function error:&error];
            if (error != nil) {
                NSLog(@" error => %@", error);
                device->HandleError("Error creating pipeline state");
                return;
            }

            // Copy over the local workgroup size as it is passed to dispatch explicitly in Metal
            localWorkgroupSize = module->GetLocalWorkGroupSize(entryPoint);

        } else {
            MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];

            for (auto stage : IterateStages(GetStageMask())) {
                const auto& module = ToBackend(builder->GetStageInfo(stage).module);

                const auto& entryPoint = builder->GetStageInfo(stage).entryPoint;
                id<MTLFunction> function = module->GetFunction(entryPoint.c_str());

                switch (stage) {
                    case nxt::ShaderStage::Vertex:
                        descriptor.vertexFunction = function;
                        break;
                    case nxt::ShaderStage::Fragment:
                        descriptor.fragmentFunction = function;
                        break;
                    case nxt::ShaderStage::Compute:
                        ASSERT(false);
                        break;
                }
            }

            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

            InputState* inputState = ToBackend(GetInputState());
            descriptor.vertexDescriptor = inputState->GetMTLVertexDescriptor();

            // TODO(kainino@chromium.org): push constants, textures, samplers

            NSError *error = nil;
            mtlRenderPipelineState = [device->GetMTLDevice()
                newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (error != nil) {
                NSLog(@" error => %@", error);
                device->HandleError("Error creating pipeline state");
                return;
            }

            MTLDepthStencilDescriptor* dsDesc = [MTLDepthStencilDescriptor new];
            dsDesc.depthWriteEnabled = true;
            dsDesc.depthCompareFunction = MTLCompareFunctionLess;
            mtlDepthStencilState = [device->GetMTLDevice()
                newDepthStencilStateWithDescriptor:dsDesc];

            [dsDesc release];
            [descriptor release];
        }
    }

    Pipeline::~Pipeline() {
        [mtlRenderPipelineState release];
        [mtlDepthStencilState release];
        [mtlComputePipelineState release];
    }

    void Pipeline::Encode(id<MTLRenderCommandEncoder> encoder) {
        ASSERT(!IsCompute());
        [encoder setDepthStencilState:mtlDepthStencilState];
        [encoder setRenderPipelineState:mtlRenderPipelineState];
    }

    void Pipeline::Encode(id<MTLComputeCommandEncoder> encoder) {
        ASSERT(IsCompute());
        [encoder setComputePipelineState:mtlComputePipelineState];
    }

    MTLSize Pipeline::GetLocalWorkGroupSize() const {
        return localWorkgroupSize;
    }

    // PipelineLayout

    PipelineLayout::PipelineLayout(Device* device, PipelineLayoutBuilder* builder)
        : PipelineLayoutBase(builder), device(device) {
        // Each stage has its own numbering namespace in CompilerMSL.
        for (auto stage : IterateStages(kAllStages)) {
            uint32_t bufferIndex = 0;
            uint32_t samplerIndex = 0;
            uint32_t textureIndex = 0;

            for (size_t group = 0; group < kMaxBindGroups; ++group) {
                const auto& groupInfo = GetBindGroupLayout(group)->GetBindingInfo();
                for (size_t binding = 0; binding < kMaxBindingsPerGroup; ++binding) {
                    if (!(groupInfo.visibilities[binding] & StageBit(stage))) {
                        continue;
                    }
                    if (!groupInfo.mask[binding]) {
                        continue;
                    }

                    switch (groupInfo.types[binding]) {
                        case nxt::BindingType::UniformBuffer:
                        case nxt::BindingType::StorageBuffer:
                            indexInfo[stage][group][binding] = bufferIndex;
                            bufferIndex++;
                            break;
                        case nxt::BindingType::Sampler:
                            indexInfo[stage][group][binding] = samplerIndex;
                            samplerIndex++;
                            break;
                        case nxt::BindingType::SampledTexture:
                            indexInfo[stage][group][binding] = textureIndex;
                            textureIndex++;
                            break;
                    }
                }
            }
        }
    }

    const PipelineLayout::BindingIndexInfo& PipelineLayout::GetBindingIndexInfo(nxt::ShaderStage stage) const {
        return indexInfo[stage];
    }

    // Queue

    Queue::Queue(Device* device, QueueBuilder* builder)
        : device(device) {
        commandQueue = [device->GetMTLDevice() newCommandQueue];
    }

    Queue::~Queue() {
        [commandQueue release];
        commandQueue = nil;
    }

    id<MTLCommandQueue> Queue::GetMTLCommandQueue() {
        return commandQueue;
    }

    void Queue::Submit(uint32_t numCommands, CommandBuffer* const * commands) {
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

        // Mutexes are necessary to prevent buffers from being written from the
        // CPU before their previous value has been read from the GPU.
        // https://developer.apple.com/library/content/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html
        // TODO(kainino@chromium.org): When we have resource transitions, all of these mutexes will be replaced.
        std::unordered_set<std::mutex*> mutexes;

        for (uint32_t i = 0; i < numCommands; ++i) {
            commands[i]->FillCommands(commandBuffer, &mutexes);
        }

        for (auto mutex : mutexes) {
            mutex->lock();
        }
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
            // 'mutexes' is copied into this Block
            for (auto mutex : mutexes) {
                mutex->unlock();
            }
        }];

        [commandBuffer commit];
    }

    // Sampler

    MTLSamplerMinMagFilter FilterModeToMinMagFilter(nxt::FilterMode mode) {
        switch (mode) {
            case nxt::FilterMode::Nearest:
                return MTLSamplerMinMagFilterNearest;
            case nxt::FilterMode::Linear:
                return MTLSamplerMinMagFilterLinear;
        }
    }

    MTLSamplerMipFilter FilterModeToMipFilter(nxt::FilterMode mode) {
        switch (mode) {
            case nxt::FilterMode::Nearest:
                return MTLSamplerMipFilterNearest;
            case nxt::FilterMode::Linear:
                return MTLSamplerMipFilterLinear;
        }
    }

    Sampler::Sampler(Device* device, SamplerBuilder* builder)
        : SamplerBase(builder), device(device) {
        auto desc = [MTLSamplerDescriptor new];
        [desc autorelease];
        desc.minFilter = FilterModeToMinMagFilter(builder->GetMinFilter());
        desc.magFilter = FilterModeToMinMagFilter(builder->GetMagFilter());
        desc.mipFilter = FilterModeToMipFilter(builder->GetMipMapFilter());
        // TODO(kainino@chromium.org): wrap modes
        mtlSamplerState = [device->GetMTLDevice() newSamplerStateWithDescriptor:desc];
    }

    Sampler::~Sampler() {
        [mtlSamplerState release];
    }

    id<MTLSamplerState> Sampler::GetMTLSamplerState() {
        return mtlSamplerState;
    }

    // ShaderModule

    ShaderModule::ShaderModule(Device* device, ShaderModuleBuilder* builder)
        : ShaderModuleBase(builder), device(device) {
        compiler = new spirv_cross::CompilerMSL(builder->AcquireSpirv());
        ExtractSpirvInfo(*compiler);

        spirv_cross::MSLConfiguration mslConfig;
        mslConfig.flip_vert_y = false;
        mslConfig.flip_frag_y = false;
        std::string msl = compiler->compile(mslConfig);

        NSString* mslSource = [NSString stringWithFormat:@"%s", msl.c_str()];
        NSError *error = nil;
        mtlLibrary = [device->GetMTLDevice() newLibraryWithSource:mslSource options:nil error:&error];
        if (error != nil) {
            NSLog(@"MTLDevice newLibraryWithSource => %@", error);
            device->HandleError("Error creating MTLLibrary from MSL source");
        }
    }

    ShaderModule::~ShaderModule() {
        delete compiler;
    }

    id<MTLFunction> ShaderModule::GetFunction(const char* functionName) const {
        // TODO(kainino@chromium.org): make this somehow more robust; it needs to behave like clean_func_name:
        // https://github.com/KhronosGroup/SPIRV-Cross/blob/4e915e8c483e319d0dd7a1fa22318bef28f8cca3/spirv_msl.cpp#L1213
        if (strcmp(functionName, "main") == 0) {
            functionName = "main0";
        }
        NSString* name = [NSString stringWithFormat:@"%s", functionName];
        return [mtlLibrary newFunctionWithName:name];
    }

    MTLSize ShaderModule::GetLocalWorkGroupSize(const std::string& entryPoint) const {
        auto size = compiler->get_entry_point(entryPoint).workgroup_size;
        return MTLSizeMake(size.x, size.y, size.z);
    }

    // Texture

    MTLPixelFormat TextureFormatPixelFormat(nxt::TextureFormat format) {
        switch (format) {
            case nxt::TextureFormat::R8G8B8A8Unorm:
                return MTLPixelFormatRGBA8Unorm;
        }
    }

    Texture::Texture(Device* device, TextureBuilder* builder)
        : TextureBase(builder), device(device) {
        auto desc = [MTLTextureDescriptor new];
        [desc autorelease];
        switch (GetDimension()) {
            case nxt::TextureDimension::e2D:
                desc.textureType = MTLTextureType2D;
                break;
        }
        desc.usage = MTLTextureUsageShaderRead;
        desc.pixelFormat = TextureFormatPixelFormat(GetFormat());
        desc.width = GetWidth();
        desc.height = GetHeight();
        desc.depth = GetDepth();
        desc.mipmapLevelCount = GetNumMipLevels();
        desc.arrayLength = 1;

        mtlTexture = [device->GetMTLDevice() newTextureWithDescriptor:desc];
    }

    Texture::~Texture() {
        [mtlTexture release];
    }

    id<MTLTexture> Texture::GetMTLTexture() {
        return mtlTexture;
    }

    // TextureView

    TextureView::TextureView(Device* device, TextureViewBuilder* builder)
        : TextureViewBase(builder), device(device) {
    }

}
}
