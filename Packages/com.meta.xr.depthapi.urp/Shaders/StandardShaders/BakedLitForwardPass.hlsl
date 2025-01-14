
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#if defined(LOD_FADE_CROSSFADE)
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LODCrossFade.hlsl"
#endif

#include "Packages/com.meta.xr.sdk.core/Shaders/EnvironmentDepth/URP/EnvironmentOcclusionURP.hlsl"
float _EnvironmentDepthBias;

struct Attributes
{
    float4 positionOS       : POSITION;
    float2 uv               : TEXCOORD0;
    float2 staticLightmapUV : TEXCOORD1;
    float3 normalOS         : NORMAL;
    float4 tangentOS        : TANGENT;

    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float3 uv0AndFogCoord : TEXCOORD0; // xy: uv0, z: fogCoord
    DECLARE_LIGHTMAP_OR_SH(staticLightmapUV, vertexSH, 1);
    half3 normalWS : TEXCOORD2;

    #if defined(_NORMALMAP)
    half4 tangentWS : TEXCOORD3;
    #endif

    #if defined(DEBUG_DISPLAY) || defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    float3 positionWS : TEXCOORD4;
    #endif

    #if defined(DEBUG_DISPLAY)
    float3 viewDirWS : TEXCOORD5;
    #endif

    #if defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    float4 positionNDC : TEXCOORD6;
    #endif

    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

void InitializeInputData(Varyings input, half3 normalTS, out InputData inputData)
{
    inputData = (InputData)0;

    #if defined(DEBUG_DISPLAY) || defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    inputData.positionWS = input.positionWS;
    #else
    inputData.positionWS = float3(0, 0, 0);
    #endif

    #if defined(DEBUG_DISPLAY)
    inputData.viewDirectionWS = input.viewDirWS;
    #else
    inputData.viewDirectionWS = half3(0, 0, 1);
    #endif

    #if defined(_NORMALMAP)
    float sgn = input.tangentWS.w;      // should be either +1 or -1
    float3 bitangent = sgn * cross(input.normalWS.xyz, input.tangentWS.xyz);

    inputData.tangentToWorld = half3x3(input.tangentWS.xyz, bitangent.xyz, input.normalWS.xyz);
    inputData.normalWS = TransformTangentToWorld(normalTS, inputData.tangentToWorld);
    #else
    inputData.normalWS = input.normalWS;
    #endif

    inputData.shadowCoord = float4(0, 0, 0, 0);
    inputData.fogCoord = input.uv0AndFogCoord.z;
    inputData.vertexLighting = half3(0, 0, 0);
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.vertexSH, inputData.normalWS);
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    inputData.shadowMask = half4(1, 1, 1, 1);

    #if defined(DEBUG_DISPLAY)
    #if defined(LIGHTMAP_ON)
    inputData.staticLightmapUV = input.staticLightmapUV;
    #else
    inputData.vertexSH = input.vertexSH;
    #endif
    #endif
}

Varyings BakedLitForwardPassVertex(Attributes input)
{
    Varyings output;

    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
    output.positionCS = vertexInput.positionCS;
    output.uv0AndFogCoord.xy = TRANSFORM_TEX(input.uv, _BaseMap);
    #if defined(_FOG_FRAGMENT)
    output.uv0AndFogCoord.z = vertexInput.positionVS.z;
    #else
    output.uv0AndFogCoord.z = ComputeFogFactor(vertexInput.positionCS.z);
    #endif

    // normalWS and tangentWS already normalize.
    // this is required to avoid skewing the direction during interpolation
    // also required for per-vertex SH evaluation
    VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
    output.normalWS = normalInput.normalWS;
    #if defined(_NORMALMAP)
    real sign = input.tangentOS.w * GetOddNegativeScale();
    output.tangentWS = half4(normalInput.tangentWS.xyz, sign);
    #endif
    OUTPUT_LIGHTMAP_UV(input.staticLightmapUV, unity_LightmapST, output.staticLightmapUV);
    OUTPUT_SH(output.normalWS, output.vertexSH);

    #if defined(DEBUG_DISPLAY) || defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    output.positionWS = vertexInput.positionWS;
    #endif

    #if defined(DEBUG_DISPLAY)
    output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
    #endif

    #if defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    output.positionNDC = vertexInput.positionNDC;
    #endif

    return output;
}

void BakedLitForwardPassFragment(
    Varyings input
    , out half4 outColor : SV_Target0
#ifdef _WRITE_RENDERING_LAYERS
    , out float4 outRenderingLayers : SV_Target1
#endif
    )
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    half2 uv = input.uv0AndFogCoord.xy;
    #if defined(_NORMALMAP)
    half3 normalTS = SampleNormal(uv, TEXTURE2D_ARGS(_BumpMap, sampler_BumpMap)).xyz;
    #else
    half3 normalTS = half3(0, 0, 1);
    #endif
    InputData inputData;
    InitializeInputData(input, normalTS, inputData);
#if UNITY_VERSION >= 600000
  SETUP_DEBUG_TEXTURE_DATA(inputData, UNDO_TRANSFORM_TEX(input.uv, _BaseMap));
#else
  SETUP_DEBUG_TEXTURE_DATA(inputData, input.uv, _BaseMap);
#endif

    half4 texColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
    half3 color = texColor.rgb * _BaseColor.rgb;
    half alpha = texColor.a * _BaseColor.a;

    alpha = AlphaDiscard(alpha, _Cutoff);
    color = AlphaModulate(color, alpha);

#ifdef LOD_FADE_CROSSFADE
    LODFadeCrossFade(input.positionCS);
#endif

#ifdef _DBUFFER
    ApplyDecalToBaseColorAndNormal(input.positionCS, color, inputData.normalWS);
#endif

    half4 finalColor = UniversalFragmentBakedLit(inputData, color, alpha, normalTS);

    finalColor.a = OutputAlpha(finalColor.a, _Surface);

#if defined(HARD_OCCLUSION) || defined(SOFT_OCCLUSION)
    META_DEPTH_OCCLUDE_OUTPUT_PREMULTIPLY_WORLDPOS_NAME(input, positionWS, finalColor, _EnvironmentDepthBias);
#endif

    outColor = finalColor;

#ifdef _WRITE_RENDERING_LAYERS
    uint renderingLayers = GetMeshRenderingLayer();
    outRenderingLayers = float4(EncodeMeshRenderingLayer(renderingLayers), 0, 0, 0);
#endif
}
