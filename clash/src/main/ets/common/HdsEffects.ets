import { hdsEffect } from '@hms.hds.hdsBaseComponent';
import {
  DualEdgeFlowLightWithMaskParam,
  HdsSceneController,
} from '@hms.hds.HdsVisualComponent';

export class HdsEffects {
  static createButtonLight(color: ResourceColor): VisualEffect {
    const light: hdsEffect.PointLightEffect = {
      sourceType: hdsEffect.PointLightSourceType.BRIGHT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
      options: {
        color,
        intensity: 0.85,
        height: 72,
        bloom: 0.55,
      },
    };
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .pointLight(light)
      .buildEffect();
  }

  static createCardLight(color: ResourceColor): VisualEffect {
    const light: hdsEffect.PointLightEffect = {
      sourceType: hdsEffect.PointLightSourceType.SOFT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
      options: {
        color,
        intensity: 0.35,
        height: 48,
        bloom: 0.22,
      },
    };
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
      .pointLight(light)
      .buildEffect();
  }

  static createHomeSceneController(): HdsSceneController {
    const params: DualEdgeFlowLightWithMaskParam = {
      backgroundMaskColors: [
        $r('app.color.page_bg'),
        $r('app.color.surface_tint'),
        $r('app.color.surface_subtle'),
      ],
      firstEdgeFlowLight: {
        startPos: 0.02,
        endPos: 0.26,
        color: $r('app.color.primary'),
      },
      secondEdgeFlowLight: {
        startPos: 0.58,
        endPos: 0.90,
        color: $r('app.color.light_beam'),
      },
    };
    return new HdsSceneController().setSceneParams(params);
  }

  static createSceneFrameRate(): hdsEffect.ExpectedFrameRateRange {
    return {
      expected: hdsEffect.FrameRateType.FRAME_RATE_30,
      min: hdsEffect.FrameRateType.FRAME_RATE_15,
      max: hdsEffect.FrameRateType.FRAME_RATE_60,
    };
  }
}
